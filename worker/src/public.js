import { mediaKind, renderGone, renderPasswordForm, renderViewer } from "./page.js";
import {
  hasPasswordCookie,
  hasValidSignature,
  now,
  passwordCookie,
  signedQuery,
  verifyPassword,
} from "./security.js";
import { deleteLink, findLink, isExpired } from "./links.js";

const LINK_PATH = /^\/([A-Za-z0-9_-]{1,64})(?:\.([a-z0-9]{1,8}))?$/;
const POSTER_PATH = /^\/([A-Za-z0-9_-]{1,64})\/poster\.jpg$/;
const BOTS = /bot|crawl|spider|slack|facebookexternalhit|whatsapp|telegram|discord|twitter|linkedin|embedly|preview|skype|pinterest|google|bing|iframely|mastodon/i;

/** Everything outside /api: file pages, raw files, posters, redirects and older direct links. */
export async function handlePublic(request, env, path, ctx) {
  if (request.method !== "GET" && request.method !== "HEAD" && request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (path === "/" || path === "") {
    return env.HOME_URL
      ? Response.redirect(env.HOME_URL, 302)
      : new Response(`${env.SITE_NAME ?? "Škljoc"}`, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  }
  const poster = path.match(POSTER_PATH);
  if (poster) return servePoster(request, env, poster[1]);

  const match = path.match(LINK_PATH);
  const link = match ? await findLink(env, match[1]) : null;
  if (link && !link.multipart_upload_id) {
    if (isExpired(link)) {
      ctx.waitUntil(deleteLink(env, link));
      return gone(env);
    }
    if (link.kind === "redirect") return match[2] ? notFound() : serveLink(request, env, link, ctx);
    // `/id.png` and `/id?direct` are the file itself, without the page around it.
    const wantsFile = Boolean(match[2]) || new URL(request.url).searchParams.has("direct");
    return wantsFile ? serveRaw(request, env, link) : serveLink(request, env, link, ctx);
  }
  return serveLegacy(request, env, path);
}

/** A file's viewer page, or the jump to a redirect's target, after privacy, password and one-time checks. */
async function serveLink(request, env, upload, ctx) {
  const url = new URL(request.url);
  const isOwner = await hasValidSignature(url, upload.id, env);
  const isBot = BOTS.test(request.headers.get("User-Agent") ?? "");

  if (upload.is_private && !isOwner) return notFound();

  if (upload.password_hash && !isOwner && !(await hasPasswordCookie(request, upload.id, env))) {
    if (request.method === "POST") {
      const form = await request.formData().catch(() => null);
      if (await verifyPassword(String(form?.get("password") ?? ""), upload.password_hash, env)) {
        return new Response(null, {
          status: 303,
          headers: { Location: `/${upload.id}`, "Set-Cookie": await passwordCookie(upload.id, env) },
        });
      }
      return html(renderPasswordForm(env, upload, true), 401);
    }
    return html(renderPasswordForm(env, upload, false), 401);
  }

  if (upload.burn && upload.burned_at && !isOwner) return gone(env);

  if (upload.kind === "redirect") {
    // Link previews follow the redirect too, so Slack shows the target, but only people are counted.
    if (!isOwner && !isBot) ctx.waitUntil(countView(env, upload));
    return new Response(null, { status: 302, headers: { Location: upload.target_url, "Cache-Control": "no-store", "Referrer-Policy": "no-referrer-when-downgrade" } });
  }

  // One-time links: the raw file stays reachable for an hour through a signed link only.
  const needsSignedRaw = Boolean(upload.is_private || upload.burn || isOwner);
  const query = needsSignedRaw ? `?${await signedQuery(upload.id, env)}` : "";

  if (!isOwner && !isBot) ctx.waitUntil(countView(env, upload));

  const isPublic = !upload.is_private && !upload.password_hash && !upload.burn;
  return html(renderViewer(env, upload, { origin: url.origin, query, showPreviewTags: isPublic && !isOwner }));
}

function countView(env, link) {
  const time = now();
  const burn = link.burn ? ", burned_at = COALESCE(burned_at, ?)" : "";
  const statement = env.DB.prepare(`UPDATE links SET views = views + 1, last_viewed_at = ?${burn} WHERE id = ?`);
  return (link.burn ? statement.bind(time, time, link.id) : statement.bind(time, link.id)).run();
}

async function serveRaw(request, env, upload) {
  const url = new URL(request.url);
  const isOwner = await hasValidSignature(url, upload.id, env);
  if ((upload.is_private || upload.burn) && !isOwner) return notFound();
  if (upload.password_hash && !isOwner && !(await hasPasswordCookie(request, upload.id, env))) return notFound();

  const isPublic = !upload.is_private && !upload.password_hash && !upload.burn;
  const download = url.searchParams.has("download") ? upload.filename : null;
  return serveObject(request, env, upload.object_key, { isPublic, download });
}

async function servePoster(request, env, id) {
  const upload = await findLink(env, id);
  if (!upload?.poster_key || isExpired(upload)) return notFound();
  const isPublic = !upload.is_private && !upload.password_hash && !upload.burn;
  if (!isPublic && !(await hasValidSignature(new URL(request.url), id, env))) return notFound();
  return serveObject(request, env, upload.poster_key, { isPublic });
}

/** Files put in the bucket some other way keep working at their old address. Škljoc's own uploads never do. */
async function serveLegacy(request, env, path) {
  let key;
  try {
    key = decodeURIComponent(path.slice(1));
  } catch {
    return notFound();
  }
  if (!key || key.startsWith("api/")) return notFound();
  const head = await env.BUCKET.head(key);
  if (!head || head.customMetadata?.skljoc === "1") return notFound();
  return serveObject(request, env, key, { isPublic: true });
}

/** Streams an object, with Range support so videos can seek. */
async function serveObject(request, env, key, { isPublic, download = null }) {
  const object = await env.BUCKET.get(key, { range: request.headers, onlyIf: request.headers });
  if (!object) return notFound();

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", isPublic ? "public, max-age=3600" : "private, no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  // Uploaded HTML, SVG and the like open without scripts, so they can't act on this domain.
  if (mediaKind(headers.get("Content-Type")) === "file") headers.set("Content-Security-Policy", "sandbox");
  if (download) headers.set("Content-Disposition", `attachment; filename*=UTF-8''${encodeURIComponent(download)}`);

  if (!("body" in object) || !object.body) {
    return new Response(null, { status: 304, headers });
  }
  if (object.range && request.headers.has("Range")) {
    const { offset, length } = resolveRange(object.range, object.size);
    headers.set("Content-Range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("Content-Length", String(length));
    return new Response(request.method === "HEAD" ? null : object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(object.size));
  return new Response(request.method === "HEAD" ? null : object.body, { headers });
}

function resolveRange(range, size) {
  if ("suffix" in range && range.suffix !== undefined) {
    const length = Math.min(range.suffix, size);
    return { offset: size - length, length };
  }
  const offset = range.offset ?? 0;
  const length = range.length ?? size - offset;
  return { offset, length };
}

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
}

function gone(env) {
  return html(renderGone(env), 410);
}

function notFound() {
  return new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } });
}
