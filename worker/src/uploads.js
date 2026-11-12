import { hashPassword, now } from "./security.js";

export async function findUpload(env, id) {
  return env.DB.prepare("SELECT * FROM uploads WHERE id = ?").bind(id).first();
}

export async function listUploads(env, { limit, offset }) {
  const { results } = await env.DB.prepare(
    "SELECT * FROM uploads WHERE multipart_upload_id IS NULL ORDER BY created_at DESC LIMIT ? OFFSET ?",
  )
    .bind(limit, offset)
    .all();
  return results;
}

export async function insertUpload(env, upload) {
  await env.DB.prepare(
    `INSERT INTO uploads (id, object_key, filename, content_type, size, width, height, duration, created_at,
       expires_at, is_private, password_hash, burn, multipart_upload_id)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      upload.id,
      upload.objectKey,
      upload.filename,
      upload.contentType,
      upload.size ?? 0,
      upload.width ?? null,
      upload.height ?? null,
      upload.duration ?? null,
      now(),
      upload.expiresAt ?? null,
      upload.isPrivate ? 1 : 0,
      upload.passwordHash ?? null,
      upload.burn ? 1 : 0,
      upload.multipartUploadId ?? null,
    )
    .run();
}

/** Turns the options Škljoc sends into column values. `undefined` leaves a column unchanged. */
export async function resolveOptions(options, env) {
  const resolved = {};
  if (options.private !== undefined) resolved.isPrivate = Boolean(options.private);
  if (options.burn !== undefined) resolved.burn = Boolean(options.burn);
  if (options.password !== undefined) {
    resolved.passwordHash = options.password ? await hashPassword(String(options.password), env) : null;
  }
  if (options.expiresIn !== undefined) {
    const seconds = Number(options.expiresIn);
    resolved.expiresAt = options.expiresIn && seconds > 0 ? now() + Math.round(seconds) : null;
  }
  return resolved;
}

export async function updateOptions(env, id, resolved) {
  const columns = {
    isPrivate: "is_private",
    burn: "burn",
    passwordHash: "password_hash",
    expiresAt: "expires_at",
  };
  const entries = Object.entries(resolved).filter(([key]) => columns[key]);
  if (entries.length === 0) return;
  const assignments = entries.map(([key]) => `${columns[key]} = ?`);
  const values = entries.map(([key, value]) => (typeof value === "boolean" ? (value ? 1 : 0) : value));
  // A one-time link that is switched on again starts fresh.
  if (resolved.burn === true) assignments.push("burned_at = NULL");
  await env.DB.prepare(`UPDATE uploads SET ${assignments.join(", ")} WHERE id = ?`)
    .bind(...values, id)
    .run();
}

export async function deleteUpload(env, upload) {
  const keys = [upload.object_key, upload.poster_key].filter(Boolean);
  if (keys.length) await env.BUCKET.delete(keys);
  await env.DB.prepare("DELETE FROM uploads WHERE id = ?").bind(upload.id).run();
}

export function isExpired(upload) {
  return upload.expires_at !== null && upload.expires_at <= now();
}

/** What the API returns about an upload. */
export function describe(upload, origin) {
  const extension = upload.object_key.split(".").pop();
  return {
    id: upload.id,
    url: `${origin}/${upload.id}`,
    rawUrl: `${origin}/${upload.id}.${extension}`,
    filename: upload.filename,
    contentType: upload.content_type,
    size: upload.size,
    width: upload.width,
    height: upload.height,
    duration: upload.duration,
    createdAt: upload.created_at,
    expiresAt: upload.expires_at,
    private: Boolean(upload.is_private),
    hasPassword: Boolean(upload.password_hash),
    burn: Boolean(upload.burn),
    burnedAt: upload.burned_at,
    views: upload.views,
    lastViewedAt: upload.last_viewed_at,
    hasPoster: Boolean(upload.poster_key),
  };
}

/** Hourly: removes expired uploads, one-time links an hour after their view, and abandoned multipart uploads. */
export async function cleanUp(env) {
  const time = now();
  const { results } = await env.DB.prepare(
    `SELECT * FROM uploads
     WHERE (expires_at IS NOT NULL AND expires_at <= ?)
        OR (burned_at IS NOT NULL AND burned_at <= ?)
        OR (multipart_upload_id IS NOT NULL AND created_at <= ?)
     LIMIT 500`,
  )
    .bind(time, time - 3600, time - 86_400)
    .all();
  for (const upload of results) {
    if (upload.multipart_upload_id) {
      await env.BUCKET.resumeMultipartUpload(upload.object_key, upload.multipart_upload_id).abort().catch(() => {});
    }
    await deleteUpload(env, upload);
  }
  return results.length;
}
