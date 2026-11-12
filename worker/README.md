# Škljoc Worker

Uploads from Škljoc go to **your own** Cloudflare account. Nothing passes through anyone else's server.

```
Škljoc ──(token)──▶ Worker on your domain ──▶ R2 (files, private bucket)
                          └──▶ D1 (views, privacy, passwords, expiry)
```

Each upload gets a short link like `https://share.example.com/aB3x9KqZ`:

- The link opens a clean viewer page with Download and Copy link buttons.
- Slack, iMessage, WhatsApp and others show a preview of the image, or of the video's first frame.
- The file itself is at `https://share.example.com/aB3x9KqZ.png`, ready for Markdown or a GitHub issue.
- Views are counted; link previews from Slack and similar don't count.
- Each link can be **private** (only you), **password-protected**, **expiring** (1 hour to 30 days) or **one-time** (gone after the first view).
- Large videos are uploaded in parts, so the 100 MB request limit doesn't matter.
- The same domain works as a URL shortener: `https://share.example.com/cv` can redirect anywhere, with click counts and the same privacy, password, expiry and one-time options. Links come from the API for now; Škljoc gets a UI for them later.
- Set `HOME_URL` in `wrangler.jsonc` to send the bare domain to your website.

## Set it up

### Option 1: one click

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/aleksandargosevski/skljoc/tree/main/worker)

1. Click the button and sign in to Cloudflare. It copies this folder to your GitHub, creates the R2 bucket and D1 database, and deploys.
2. When asked for `UPLOAD_TOKEN`, paste a long random string. In Terminal, `openssl rand -hex 32` makes one.
3. Optional: in the Cloudflare dashboard, open the Worker → **Settings → Domains & Routes → Add → Custom domain** to put it on your own domain, e.g. `share.example.com`.
4. In Škljoc → **Settings → Upload**, enter the Worker's address and the same token, then press **Test Connection**.

### Option 2: from the terminal

```sh
git clone https://github.com/aleksandargosevski/skljoc
cd skljoc/worker
./setup.sh --domain share.example.com            # new bucket "skljoc"
./setup.sh --bucket my-bucket --domain share.example.com   # or reuse a bucket
```

The script does everything in order:

1. Asks you to log in to Cloudflare if needed.
2. Creates whatever is missing.
3. Deploys the Worker.
4. Copies a new token to the clipboard.
5. Tells you what to enter in Škljoc.

Your bucket, database and domain are written to `wrangler.local.jsonc`, which isn't committed, so `wrangler.jsonc` stays a clean template. To deploy changes later, run `npx wrangler deploy --config wrangler.local.jsonc`.

## Using a bucket you already share files from

If your bucket already has a public custom domain (for example, links made with `aws s3 cp`), the Worker can take that domain over and keep the old links working:

1. In the dashboard: **R2 → your bucket → Settings → Custom Domains**, remove the domain. The Worker can't use it while the bucket does.
2. Run `./setup.sh --bucket your-bucket --domain share.example.com`.

Files that Škljoc didn't upload are still served at their old address, so `share.example.com/some-file.pdf` keeps working. Škljoc's own uploads are only reachable through their links, so private and password-protected ones stay that way.

## Cost

Personal use fits in Cloudflare's free tiers:

| | Free | After that |
|---|---|---|
| Workers | 100,000 requests a day | $5 a month for the paid plan |
| R2 storage | 10 GB a month | $0.015 per GB a month |
| R2 downloads | always free | — |
| D1 | 5 million reads and 100,000 writes a day | — |

10 GB is roughly 30,000 screenshots or 500 short videos.

## Development

```sh
npm install
cp .dev.vars.example .dev.vars    # set UPLOAD_TOKEN
npm run dev                       # local Worker with local R2 and D1 on :8787
SKLJOC_TOKEN=<token> npm test     # end-to-end checks against it
```

Expired, viewed one-time and abandoned uploads are removed every hour by a Cron Trigger.

## API

Every `/api` route needs `Authorization: Bearer <UPLOAD_TOKEN>`.

| Method | Path | |
|---|---|---|
| `GET` | `/api/health` | `{ ok, version, siteName }` |
| `POST` | `/api/uploads` | Upload a file (body). See the headers below. |
| `POST` | `/api/uploads/multipart` | Start a multipart upload (same headers): `{ id, uploadId }` |
| `PUT` | `/api/uploads/multipart/:id/:part` | Upload part 1, 2, …: `{ partNumber, etag }` |
| `POST` | `/api/uploads/multipart/:id/complete` | `{ parts: [{ partNumber, etag }] }` |
| `DELETE` | `/api/uploads/multipart/:id` | Abort a multipart upload |
| `PUT` | `/api/uploads/:id/poster` | JPEG still frame for a video's link previews |
| `GET` | `/api/uploads?limit=&offset=` | `{ uploads, nextOffset }` |
| `GET` | `/api/uploads/:id` | One upload |
| `PATCH` | `/api/uploads/:id` | Change `private`, `password`, `expiresIn` or `burn` |
| `DELETE` | `/api/uploads/:id` | Delete the file and its link |
| `POST` | `/api/links` | Create a redirect. Body: `{ url, slug?, private?, password?, expiresIn?, burn? }`. Without a slug, a random 5-character one is used. |
| `GET` | `/api/links?limit=&offset=` | `{ links, nextOffset }` |
| `GET`, `PATCH`, `DELETE` | `/api/links/:id` | Works for redirects and uploads; `PATCH` also takes a new `url` |

Upload headers:

- `Content-Type`: the file's type.
- `X-Skljoc-Filename`: the URI-encoded name, with an extension.
- `X-Skljoc-Options`: base64url JSON such as `{ "private": false, "password": null, "expiresIn": 86400, "burn": false, "width": 1920, "height": 1080, "duration": 12.5 }`.

The owner opens private and one-time uploads with `?exp=<unix seconds>&sig=<hex>`, where `sig` is HMAC-SHA256(UPLOAD_TOKEN, `view.<id>.<exp>`).
