import { hashPassword, now } from "./security.js";

/** Paths a link may use: letters, digits, - and _, up to 64 characters. */
export const SLUG = /^[A-Za-z0-9_-]{1,64}$/;
const RESERVED = new Set(["api", "favicon.ico", "robots.txt"]);

export function isValidSlug(slug) {
  return SLUG.test(slug) && !RESERVED.has(slug.toLowerCase());
}

export async function findLink(env, id) {
  return env.DB.prepare("SELECT * FROM links WHERE id = ?").bind(id).first();
}

export async function listLinks(env, { kind, limit, offset }) {
  const { results } = await env.DB.prepare(
    "SELECT * FROM links WHERE kind = ? AND multipart_upload_id IS NULL ORDER BY created_at DESC LIMIT ? OFFSET ?",
  )
    .bind(kind, limit, offset)
    .all();
  return results;
}

export async function insertLink(env, link) {
  await env.DB.prepare(
    `INSERT INTO links (id, kind, target_url, object_key, filename, content_type, size, width, height, duration,
       multipart_upload_id, created_at, expires_at, is_private, password_hash, burn)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      link.id,
      link.kind,
      link.targetUrl ?? null,
      link.objectKey ?? null,
      link.filename ?? null,
      link.contentType ?? null,
      link.size ?? 0,
      link.width ?? null,
      link.height ?? null,
      link.duration ?? null,
      link.multipartUploadId ?? null,
      now(),
      link.expiresAt ?? null,
      link.isPrivate ? 1 : 0,
      link.passwordHash ?? null,
      link.burn ? 1 : 0,
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

export async function updateOptions(env, id, resolved, targetUrl) {
  const columns = {
    isPrivate: "is_private",
    burn: "burn",
    passwordHash: "password_hash",
    expiresAt: "expires_at",
  };
  const entries = Object.entries(resolved).filter(([key]) => columns[key]);
  const assignments = entries.map(([key]) => `${columns[key]} = ?`);
  const values = entries.map(([key, value]) => (typeof value === "boolean" ? (value ? 1 : 0) : value));
  if (targetUrl !== undefined) {
    assignments.push("target_url = ?");
    values.push(targetUrl);
  }
  // A one-time link that is switched on again starts fresh.
  if (resolved.burn === true) assignments.push("burned_at = NULL");
  if (assignments.length === 0) return;
  await env.DB.prepare(`UPDATE links SET ${assignments.join(", ")} WHERE id = ?`)
    .bind(...values, id)
    .run();
}

export async function deleteLink(env, link) {
  const keys = [link.object_key, link.poster_key].filter(Boolean);
  if (keys.length) await env.BUCKET.delete(keys);
  await env.DB.prepare("DELETE FROM links WHERE id = ?").bind(link.id).run();
}

export function isExpired(link) {
  return link.expires_at !== null && link.expires_at <= now();
}

/** What the API returns about a link. */
export function describe(link, origin) {
  const common = {
    id: link.id,
    kind: link.kind,
    url: `${origin}/${link.id}`,
    createdAt: link.created_at,
    expiresAt: link.expires_at,
    private: Boolean(link.is_private),
    hasPassword: Boolean(link.password_hash),
    burn: Boolean(link.burn),
    burnedAt: link.burned_at,
    views: link.views,
    lastViewedAt: link.last_viewed_at,
  };
  if (link.kind === "redirect") return { ...common, targetUrl: link.target_url };
  const extension = link.object_key.split(".").pop();
  return {
    ...common,
    rawUrl: `${origin}/${link.id}.${extension}`,
    filename: link.filename,
    contentType: link.content_type,
    size: link.size,
    width: link.width,
    height: link.height,
    duration: link.duration,
    hasPoster: Boolean(link.poster_key),
  };
}

/** Hourly: removes expired links, one-time links an hour after their view, and abandoned multipart uploads. */
export async function cleanUp(env) {
  const time = now();
  const { results } = await env.DB.prepare(
    `SELECT * FROM links
     WHERE (expires_at IS NOT NULL AND expires_at <= ?)
        OR (burned_at IS NOT NULL AND burned_at <= ?)
        OR (multipart_upload_id IS NOT NULL AND created_at <= ?)
     LIMIT 500`,
  )
    .bind(time, time - 3600, time - 86_400)
    .all();
  for (const link of results) {
    if (link.multipart_upload_id) {
      await env.BUCKET.resumeMultipartUpload(link.object_key, link.multipart_upload_id).abort().catch(() => {});
    }
    await deleteLink(env, link);
  }
  return results.length;
}
