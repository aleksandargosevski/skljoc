const encoder = new TextEncoder();
const ID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

/** True when the request carries the upload token as a Bearer token. */
export async function isAuthorized(request, env) {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  return Boolean(env.UPLOAD_TOKEN) && (await equalSecrets(token, env.UPLOAD_TOKEN));
}

/** Eight unambiguous random characters (no 0/O, 1/l/I), about 46 bits. */
export function newId(length = 8) {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return Array.from(bytes, (byte) => ID_ALPHABET[byte % ID_ALPHABET.length]).join("");
}

export async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return toHex(new Uint8Array(signature));
}

/**
 * Owner links for private uploads: `?exp=<unix seconds>&sig=<hex>`, where sig is
 * HMAC-SHA256(UPLOAD_TOKEN, "view.<id>.<exp>"). Škljoc creates the same signature.
 */
export async function hasValidSignature(url, id, env) {
  const expires = Number(url.searchParams.get("exp"));
  const signature = url.searchParams.get("sig") ?? "";
  if (!Number.isFinite(expires) || expires < now() || !signature) return false;
  const expected = await hmacHex(env.UPLOAD_TOKEN, `view.${id}.${expires}`);
  return equalSecrets(signature, expected);
}

export async function signedQuery(id, env, lifetimeSeconds = 3600) {
  const expires = now() + lifetimeSeconds;
  const signature = await hmacHex(env.UPLOAD_TOKEN, `view.${id}.${expires}`);
  return `exp=${expires}&sig=${signature}`;
}

/**
 * Passwords are hashed with HMAC keyed by the upload token (a pepper) and a random salt.
 * This is fast enough for the Workers free plan, and useless to anyone without the token.
 */
export async function hashPassword(password, env) {
  const salt = toHex(crypto.getRandomValues(new Uint8Array(16)));
  return `hmac$${salt}$${await hmacHex(env.UPLOAD_TOKEN, `${salt}:${password}`)}`;
}

export async function verifyPassword(password, stored, env) {
  const [scheme, salt, hash] = (stored ?? "").split("$");
  if (scheme !== "hmac" || !salt || !hash) return false;
  return equalSecrets(await hmacHex(env.UPLOAD_TOKEN, `${salt}:${password}`), hash);
}

/** A cookie that remembers a correct password for a day. */
export async function passwordCookie(id, env) {
  const expires = now() + 86_400;
  const signature = await hmacHex(env.UPLOAD_TOKEN, `password.${id}.${expires}`);
  return `sk_${id}=${expires}.${signature}; Path=/; Max-Age=86400; HttpOnly; Secure; SameSite=Lax`;
}

export async function hasPasswordCookie(request, id, env) {
  const cookie = (request.headers.get("Cookie") ?? "")
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`sk_${id}=`));
  if (!cookie) return false;
  const [expires, signature] = cookie.slice(`sk_${id}=`.length).split(".");
  if (!(Number(expires) > now()) || !signature) return false;
  return equalSecrets(signature, await hmacHex(env.UPLOAD_TOKEN, `password.${id}.${expires}`));
}

export function now() {
  return Math.floor(Date.now() / 1000);
}

async function equalSecrets(a, b) {
  const left = encoder.encode(String(a));
  const right = encoder.encode(String(b));
  if (left.byteLength !== right.byteLength) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}

function toHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
