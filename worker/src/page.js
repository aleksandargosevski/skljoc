/** The pages people see when they open a link. */

export function renderViewer(env, upload, { origin, query, showPreviewTags }) {
  const extension = upload.object_key.split(".").pop();
  const raw = `/${upload.id}.${extension}${query}`;
  const download = `${raw}${query ? "&" : "?"}download`;
  const pageUrl = `${origin}/${upload.id}`;
  const isVideo = upload.content_type.startsWith("video/");
  const poster = upload.poster_key ? `/${upload.id}/poster.jpg${query}` : "";
  const title = upload.filename || "Screenshot";

  const media = isVideo
    ? `<video src="${attr(raw)}" ${poster ? `poster="${attr(poster)}"` : ""} controls autoplay muted loop playsinline></video>`
    : `<img src="${attr(raw)}" alt="${attr(title)}">`;

  const previewTags = showPreviewTags ? previewMeta({ upload, origin, pageUrl, extension, isVideo, title }) : `<meta name="robots" content="noindex">`;

  return page(env, title, `
    ${previewTags}
  `, `
    <main>${media}</main>
    <footer>
      <span class="name" title="${attr(title)}">${text(title)}</span>
      <span class="actions">
        <a class="button" href="${attr(raw)}" title="Just the file, without this page">Direct link</a>
        <a class="button" href="${attr(download)}">Download</a>
        <button class="button" id="copy" data-url="${attr(pageUrl)}">Copy link</button>
      </span>
    </footer>
    <script>
      const copy = document.getElementById("copy");
      copy.addEventListener("click", async () => {
        await navigator.clipboard.writeText(copy.dataset.url);
        copy.textContent = "Copied";
        setTimeout(() => (copy.textContent = "Copy link"), 1500);
      });
    </script>
  `);
}

export function renderPasswordForm(env, upload, wrong) {
  return page(env, "Password required", `<meta name="robots" content="noindex">`, `
    <main class="center">
      <form method="post" class="card">
        <h1>This link is protected</h1>
        <p>Enter the password to see it.</p>
        <input type="password" name="password" autofocus required placeholder="Password" autocomplete="off">
        ${wrong ? `<p class="error">That password isn't right.</p>` : ""}
        <button class="button primary" type="submit">Open</button>
      </form>
    </main>
  `);
}

export function renderGone(env) {
  return page(env, "Link expired", `<meta name="robots" content="noindex">`, `
    <main class="center">
      <div class="card">
        <h1>This link has expired</h1>
        <p>It was set to disappear, and it has.</p>
      </div>
    </main>
  `);
}

function previewMeta({ upload, origin, pageUrl, extension, isVideo, title }) {
  const rawUrl = `${origin}/${upload.id}.${extension}`;
  const image = isVideo ? (upload.poster_key ? `${origin}/${upload.id}/poster.jpg` : "") : rawUrl;
  const size = upload.width && upload.height
    ? `<meta property="og:image:width" content="${upload.width}"><meta property="og:image:height" content="${upload.height}">`
    : "";
  return `
    <meta property="og:type" content="${isVideo ? "video.other" : "website"}">
    <meta property="og:title" content="${attr(title)}">
    <meta property="og:url" content="${attr(pageUrl)}">
    ${image ? `<meta property="og:image" content="${attr(image)}">${isVideo ? "" : size}` : ""}
    ${isVideo ? `<meta property="og:video" content="${attr(rawUrl)}"><meta property="og:video:type" content="${attr(upload.content_type)}">${size.replaceAll("og:image", "og:video")}` : ""}
    <meta name="twitter:card" content="summary_large_image">
    ${image ? `<meta name="twitter:image" content="${attr(image)}">` : ""}
  `;
}

function page(env, title, head, body) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${text(title)} · ${text(env.SITE_NAME ?? "Škljoc")}</title>
  ${head}
  <style>
    :root { color-scheme: dark; --bg: #111214; --panel: #1b1c20; --text: #e8e8ea; --muted: #8e9099; --accent: #7f5af0; }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { display: flex; flex-direction: column; }
    main { flex: 1; display: flex; align-items: center; justify-content: center; padding: 24px; min-height: 0; }
    main img, main video { max-width: 100%; max-height: calc(100vh - 120px); border-radius: 8px; box-shadow: 0 10px 40px rgba(0,0,0,.5); }
    footer { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 12px 20px; background: var(--panel); border-top: 1px solid #ffffff12; }
    .name { color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .actions { display: flex; gap: 8px; flex-shrink: 0; }
    .button { appearance: none; border: 1px solid #ffffff22; background: #ffffff10; color: var(--text); padding: 8px 14px; border-radius: 8px; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer; }
    .button:hover { background: #ffffff1c; }
    .button.primary { background: var(--accent); border-color: transparent; width: 100%; margin-top: 8px; }
    .center { text-align: center; }
    .card { background: var(--panel); padding: 28px; border-radius: 14px; width: min(360px, 100%); border: 1px solid #ffffff12; }
    .card h1 { font-size: 19px; margin: 0 0 6px; }
    .card p { color: var(--muted); margin: 0 0 14px; }
    .card input { width: 100%; padding: 10px 12px; border-radius: 8px; border: 1px solid #ffffff22; background: #0d0d0f; color: var(--text); font: inherit; }
    .error { color: #ff6b6b !important; margin: 10px 0 0 !important; }
  </style>
</head>
<body>
${body}
</body>
</html>`;
}

function text(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

const attr = text;
