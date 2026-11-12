import { newId } from "./security.js";
import {
  deleteUpload,
  describe,
  findUpload,
  insertUpload,
  listUploads,
  resolveOptions,
  updateOptions,
} from "./uploads.js";

export const VERSION = 1;

/** Routes under /api. Every route needs the upload token. */
export async function handleApi(request, env, path) {
  const origin = new URL(request.url).origin;
  const method = request.method;
  const parts = path.split("/").filter(Boolean); // ["api", ...]

  if (parts[1] === "health" && method === "GET") {
    return json({ ok: true, version: VERSION, siteName: env.SITE_NAME ?? "Škljoc" });
  }
  if (parts[1] !== "uploads") return error(404, "Unknown API route");

  // /api/uploads
  if (parts.length === 2) {
    if (method === "GET") return list(request, env, origin);
    if (method === "POST") return uploadWhole(request, env, origin);
  }

  // /api/uploads/multipart...
  if (parts[2] === "multipart") {
    if (parts.length === 3 && method === "POST") return startMultipart(request, env);
    const id = parts[3];
    if (parts.length === 5 && parts[4] === "complete" && method === "POST") return completeMultipart(request, env, id, origin);
    if (parts.length === 5 && method === "PUT") return uploadPart(request, env, id, Number(parts[4]));
    if (parts.length === 4 && method === "DELETE") return abortMultipart(request, env, id);
    return error(404, "Unknown multipart route");
  }

  // /api/uploads/:id(/poster)
  const upload = await findUpload(env, parts[2]);
  if (!upload) return error(404, "No such upload");
  if (parts[3] === "poster" && method === "PUT") return putPoster(request, env, upload);
  if (parts.length === 3) {
    if (method === "GET") return json(describe(upload, origin));
    if (method === "PATCH") {
      const options = await request.json().catch(() => null);
      if (!options) return error(400, "Expected JSON options");
      await updateOptions(env, upload.id, await resolveOptions(options, env));
      return json(describe(await findUpload(env, upload.id), origin));
    }
    if (method === "DELETE") {
      await deleteUpload(env, upload);
      return json({ deleted: upload.id });
    }
  }
  return error(405, "Method not allowed");
}

/**
 * Whole-file upload: the body is the file. Details travel in headers:
 * `X-Skljoc-Filename` (URI-encoded) and `X-Skljoc-Options` (base64url JSON with
 * private, password, expiresIn, burn, width, height, duration).
 */
async function uploadWhole(request, env, origin) {
  const length = Number(request.headers.get("Content-Length"));
  if (!request.body || !(length > 0)) return error(411, "Content-Length is required");
  const details = readDetails(request);
  if (details.error) return error(400, details.error);

  const id = await uniqueId(env);
  const objectKey = `${id}.${details.extension}`;
  await env.BUCKET.put(objectKey, request.body, {
    httpMetadata: { contentType: details.contentType },
    customMetadata: { skljoc: "1", filename: details.filename },
  });
  await insertUpload(env, {
    id,
    objectKey,
    filename: details.filename,
    contentType: details.contentType,
    size: length,
    ...details.media,
    ...(await resolveOptions(details.options, env)),
  });
  return json(describe(await findUpload(env, id), origin), 201);
}

/** Starts a multipart upload for files over the 100 MB request limit. */
async function startMultipart(request, env) {
  const details = readDetails(request);
  if (details.error) return error(400, details.error);
  const id = await uniqueId(env);
  const objectKey = `${id}.${details.extension}`;
  const multipart = await env.BUCKET.createMultipartUpload(objectKey, {
    httpMetadata: { contentType: details.contentType },
    customMetadata: { skljoc: "1", filename: details.filename },
  });
  await insertUpload(env, {
    id,
    objectKey,
    filename: details.filename,
    contentType: details.contentType,
    multipartUploadId: multipart.uploadId,
    ...details.media,
    ...(await resolveOptions(details.options, env)),
  });
  return json({ id, uploadId: multipart.uploadId }, 201);
}

async function uploadPart(request, env, id, partNumber) {
  const upload = await findUpload(env, id);
  if (!upload?.multipart_upload_id) return error(404, "No multipart upload in progress");
  if (!(partNumber >= 1 && partNumber <= 10_000) || !request.body) return error(400, "Invalid part");
  const multipart = env.BUCKET.resumeMultipartUpload(upload.object_key, upload.multipart_upload_id);
  const part = await multipart.uploadPart(partNumber, request.body);
  return json({ partNumber: part.partNumber, etag: part.etag });
}

async function completeMultipart(request, env, id, origin) {
  const upload = await findUpload(env, id);
  if (!upload?.multipart_upload_id) return error(404, "No multipart upload in progress");
  const body = await request.json().catch(() => null);
  if (!Array.isArray(body?.parts) || body.parts.length === 0) return error(400, "Expected { parts: [{ partNumber, etag }] }");
  const multipart = env.BUCKET.resumeMultipartUpload(upload.object_key, upload.multipart_upload_id);
  const object = await multipart.complete(body.parts);
  await env.DB.prepare("UPDATE uploads SET multipart_upload_id = NULL, size = ? WHERE id = ?")
    .bind(object.size, id)
    .run();
  return json(describe(await findUpload(env, id), origin), 201);
}

async function abortMultipart(request, env, id) {
  const upload = await findUpload(env, id);
  if (!upload?.multipart_upload_id) return error(404, "No multipart upload in progress");
  await env.BUCKET.resumeMultipartUpload(upload.object_key, upload.multipart_upload_id).abort();
  await env.DB.prepare("DELETE FROM uploads WHERE id = ?").bind(id).run();
  return json({ aborted: id });
}

/** A still frame for videos, used for link previews in Slack, iMessage and others. */
async function putPoster(request, env, upload) {
  if (!request.body) return error(400, "Expected a JPEG body");
  const posterKey = `${upload.id}-poster.jpg`;
  await env.BUCKET.put(posterKey, request.body, {
    httpMetadata: { contentType: "image/jpeg" },
    customMetadata: { skljoc: "1" },
  });
  await env.DB.prepare("UPDATE uploads SET poster_key = ? WHERE id = ?").bind(posterKey, upload.id).run();
  return json({ ok: true });
}

async function list(request, env, origin) {
  const url = new URL(request.url);
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 50, 1), 200);
  const offset = Math.max(Number(url.searchParams.get("offset")) || 0, 0);
  const uploads = await listUploads(env, { limit, offset });
  return json({
    uploads: uploads.map((upload) => describe(upload, origin)),
    nextOffset: uploads.length === limit ? offset + limit : null,
  });
}

function readDetails(request) {
  let filename = "upload";
  try {
    filename = decodeURIComponent(request.headers.get("X-Skljoc-Filename") ?? "upload").slice(0, 200);
  } catch {
    return { error: "X-Skljoc-Filename must be URI-encoded" };
  }
  const extension = (filename.includes(".") ? filename.split(".").pop() : "").toLowerCase();
  if (!/^[a-z0-9]{1,8}$/.test(extension)) return { error: "The filename needs an extension like .png or .mp4" };

  let options = {};
  const encoded = request.headers.get("X-Skljoc-Options");
  if (encoded) {
    try {
      options = JSON.parse(new TextDecoder().decode(base64UrlDecode(encoded)));
    } catch {
      return { error: "X-Skljoc-Options must be base64url-encoded JSON" };
    }
  }
  const media = {
    width: Number.isFinite(options.width) ? Math.round(options.width) : null,
    height: Number.isFinite(options.height) ? Math.round(options.height) : null,
    duration: Number.isFinite(options.duration) ? options.duration : null,
  };
  const contentType = request.headers.get("Content-Type") || "application/octet-stream";
  return { filename, extension, contentType, options, media };
}

async function uniqueId(env) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const id = newId();
    if (!(await findUpload(env, id))) return id;
  }
  throw new Error("Could not find a free id");
}

function base64UrlDecode(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

export function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export function error(status, message) {
  return json({ error: message }, status);
}
