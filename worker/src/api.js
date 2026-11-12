import {
  deleteLink,
  describe,
  findLink,
  insertLink,
  isValidSlug,
  listLinks,
  resolveOptions,
  updateOptions,
} from "./links.js";
import { newId } from "./security.js";

export const VERSION = 1;

/** Routes under /api. Every route needs the upload token. */
export async function handleApi(request, env, path) {
  const origin = new URL(request.url).origin;
  const method = request.method;
  const parts = path.split("/").filter(Boolean); // ["api", ...]

  if (parts[1] === "health" && method === "GET") {
    return json({ ok: true, version: VERSION, siteName: env.SITE_NAME ?? "Škljoc" });
  }

  if (parts[1] === "uploads") {
    if (parts.length === 2) {
      if (method === "GET") return list(request, env, origin, "file");
      if (method === "POST") return uploadWhole(request, env, origin);
    }
    if (parts[2] === "multipart") {
      if (parts.length === 3 && method === "POST") return startMultipart(request, env);
      const id = parts[3];
      if (parts.length === 5 && parts[4] === "complete" && method === "POST") return completeMultipart(request, env, id, origin);
      if (parts.length === 5 && method === "PUT") return uploadPart(request, env, id, Number(parts[4]));
      if (parts.length === 4 && method === "DELETE") return abortMultipart(env, id);
      return error(404, "Unknown multipart route");
    }
    if (parts[3] === "poster" && method === "PUT") {
      const link = await findLink(env, parts[2]);
      if (link?.kind !== "file") return error(404, "No such upload");
      return putPoster(request, env, link);
    }
    if (parts.length === 3) return single(request, env, origin, parts[2]);
  }

  if (parts[1] === "links") {
    if (parts.length === 2) {
      if (method === "GET") return list(request, env, origin, "redirect");
      if (method === "POST") return createRedirect(request, env, origin);
    }
    if (parts.length === 3) return single(request, env, origin, parts[2]);
  }

  return error(404, "Unknown API route");
}

/** GET, PATCH and DELETE for one link of either kind. */
async function single(request, env, origin, id) {
  const link = await findLink(env, id);
  if (!link) return error(404, "No such link");
  switch (request.method) {
    case "GET":
      return json(describe(link, origin));
    case "PATCH": {
      const options = await request.json().catch(() => null);
      if (!options) return error(400, "Expected JSON options");
      let targetUrl;
      if (options.url !== undefined) {
        if (link.kind !== "redirect") return error(400, "Only redirects have a target URL");
        targetUrl = validTarget(options.url);
        if (!targetUrl) return error(400, "The target must be an http(s) URL");
      }
      await updateOptions(env, link.id, await resolveOptions(options, env), targetUrl);
      return json(describe(await findLink(env, link.id), origin));
    }
    case "DELETE":
      await deleteLink(env, link);
      return json({ deleted: link.id });
    default:
      return error(405, "Method not allowed");
  }
}

// MARK: Redirects

/** `{ url, slug?, private?, password?, expiresIn?, burn? }`. Without a slug, a random one is picked. */
async function createRedirect(request, env, origin) {
  const body = await request.json().catch(() => null);
  const targetUrl = validTarget(body?.url);
  if (!targetUrl) return error(400, "The target must be an http(s) URL");
  let id = body.slug ? String(body.slug) : await uniqueId(env, 5);
  if (!isValidSlug(id)) return error(400, "Slugs use letters, digits, - and _ (up to 64)");
  if (await findLink(env, id)) return error(409, `“${id}” is taken`);
  await insertLink(env, { id, kind: "redirect", targetUrl, ...(await resolveOptions(body, env)) });
  return json(describe(await findLink(env, id), origin), 201);
}

function validTarget(value) {
  try {
    const url = new URL(String(value ?? ""));
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : null;
  } catch {
    return null;
  }
}

// MARK: Files

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
  await insertLink(env, {
    id,
    kind: "file",
    objectKey,
    filename: details.filename,
    contentType: details.contentType,
    size: length,
    ...details.media,
    ...(await resolveOptions(details.options, env)),
  });
  return json(describe(await findLink(env, id), origin), 201);
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
  await insertLink(env, {
    id,
    kind: "file",
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
  const link = await findLink(env, id);
  if (!link?.multipart_upload_id) return error(404, "No multipart upload in progress");
  if (!(partNumber >= 1 && partNumber <= 10_000) || !request.body) return error(400, "Invalid part");
  const multipart = env.BUCKET.resumeMultipartUpload(link.object_key, link.multipart_upload_id);
  const part = await multipart.uploadPart(partNumber, request.body);
  return json({ partNumber: part.partNumber, etag: part.etag });
}

async function completeMultipart(request, env, id, origin) {
  const link = await findLink(env, id);
  if (!link?.multipart_upload_id) return error(404, "No multipart upload in progress");
  const body = await request.json().catch(() => null);
  if (!Array.isArray(body?.parts) || body.parts.length === 0) return error(400, "Expected { parts: [{ partNumber, etag }] }");
  const multipart = env.BUCKET.resumeMultipartUpload(link.object_key, link.multipart_upload_id);
  const object = await multipart.complete(body.parts);
  await env.DB.prepare("UPDATE links SET multipart_upload_id = NULL, size = ? WHERE id = ?")
    .bind(object.size, id)
    .run();
  return json(describe(await findLink(env, id), origin), 201);
}

async function abortMultipart(env, id) {
  const link = await findLink(env, id);
  if (!link?.multipart_upload_id) return error(404, "No multipart upload in progress");
  await env.BUCKET.resumeMultipartUpload(link.object_key, link.multipart_upload_id).abort();
  await env.DB.prepare("DELETE FROM links WHERE id = ?").bind(id).run();
  return json({ aborted: id });
}

/** A still frame for videos, used for link previews in Slack, iMessage and others. */
async function putPoster(request, env, link) {
  if (!request.body) return error(400, "Expected a JPEG body");
  const posterKey = `${link.id}-poster.jpg`;
  await env.BUCKET.put(posterKey, request.body, {
    httpMetadata: { contentType: "image/jpeg" },
    customMetadata: { skljoc: "1" },
  });
  await env.DB.prepare("UPDATE links SET poster_key = ? WHERE id = ?").bind(posterKey, link.id).run();
  return json({ ok: true });
}

// MARK: Helpers

async function list(request, env, origin, kind) {
  const url = new URL(request.url);
  const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 50, 1), 200);
  const offset = Math.max(Number(url.searchParams.get("offset")) || 0, 0);
  const links = await listLinks(env, { kind, limit, offset });
  const key = kind === "file" ? "uploads" : "links";
  return json({
    [key]: links.map((link) => describe(link, origin)),
    nextOffset: links.length === limit ? offset + limit : null,
  });
}

function readDetails(request) {
  let filename = "upload";
  try {
    filename = decodeURIComponent(request.headers.get("X-Skljoc-Filename") ?? "upload").slice(0, 200);
  } catch {
    return { error: "X-Skljoc-Filename must be URI-encoded" };
  }
  // The stored file keeps a short, safe extension; names without one (Makefile, README) are stored as .bin.
  const candidate = (filename.includes(".") ? filename.split(".").pop() : "").toLowerCase();
  const extension = /^[a-z0-9]{1,8}$/.test(candidate) ? candidate : "bin";

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

async function uniqueId(env, length = 8) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const id = newId(length);
    if (!(await findLink(env, id))) return id;
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
