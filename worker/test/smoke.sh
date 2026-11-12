#!/usr/bin/env bash
# End-to-end check against a running Worker (default: `npm run dev` on localhost:8787).
# Usage: SKLJOC_URL=http://localhost:8787 SKLJOC_TOKEN=... test/smoke.sh
set -euo pipefail

URL="${SKLJOC_URL:-http://localhost:8787}"
TOKEN="${SKLJOC_TOKEN:?Set SKLJOC_TOKEN to the UPLOAD_TOKEN of the Worker}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected $expected, got $actual"
    failures=$((failures + 1))
  fi
}

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
auth=(-H "Authorization: Bearer $TOKEN")
options() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
field() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# A small PNG and a 12 MB "video" for multipart.
printf '\x89PNG\r\n\x1a\n' > "$WORK/shot.png"
head -c 4096 /dev/urandom >> "$WORK/shot.png"
head -c 12582912 /dev/urandom > "$WORK/video.mp4"

opt_media=$(options '{"width":800,"height":600}')
opt_private=$(options '{"private":true}')
opt_password=$(options '{"password":"čarobna reč"}')
opt_burn=$(options '{"burn":true}')
expiry_json='{"expiresIn":1}'

check "health needs the token" 401 "$(status "$URL/api/health")"
check "health with the token" 200 "$(status "${auth[@]}" "$URL/api/health")"

# Public upload
public=$(curl -sf "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: Shot%201.png" \
  -H "X-Skljoc-Options: $opt_media" --data-binary @"$WORK/shot.png" "$URL/api/uploads")
id=$(field id <<<"$public")
check "public page" 200 "$(status "$URL/$id")"
check "public raw" 200 "$(status "$URL/$id.png")"
check "raw bytes match" "$(wc -c < "$WORK/shot.png" | tr -d ' ')" "$(curl -s "$URL/$id.png" | wc -c | tr -d ' ')"
check "?direct serves the file" "image/png" "$(curl -s -o /dev/null -w '%{content_type}' "$URL/$id?direct")"
check "?direct bytes match" "$(wc -c < "$WORK/shot.png" | tr -d ' ')" "$(curl -s "$URL/$id?direct" | wc -c | tr -d ' ')"
check "page has a direct link" 1 "$(curl -s "$URL/$id" | grep -c '>Direct link<' || true)"
check "range request" 206 "$(status -H 'Range: bytes=0-99' "$URL/$id.png")"
preview_tags=$(curl -s "$URL/$id" | grep -c 'property="og:image"' || true)
check "preview tags" 1 "$preview_tags"
curl -s -A "Mozilla/5.0" "$URL/$id" > /dev/null
curl -s -A "Slackbot-LinkExpanding 1.0" "$URL/$id" > /dev/null
sleep 1
check "views count people, not bots (three curl checks + one browser)" 4 "$(curl -s "${auth[@]}" "$URL/api/uploads/$id" | field views)"

# Private upload: hidden without a signature
private=$(curl -sf "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: secret.png" \
  -H "X-Skljoc-Options: $opt_private" --data-binary @"$WORK/shot.png" "$URL/api/uploads")
pid=$(field id <<<"$private")
check "private page hidden" 404 "$(status "$URL/$pid")"
check "private raw hidden" 404 "$(status "$URL/$pid.png")"
check "private ?direct hidden" 404 "$(status "$URL/$pid?direct")"
exp=$(( $(date +%s) + 600 ))
sig=$(printf 'view.%s.%s' "$pid" "$exp" | openssl dgst -sha256 -hmac "$TOKEN" | awk '{print $NF}')
check "private page with a signature" 200 "$(status "$URL/$pid?exp=$exp&sig=$sig")"
check "private raw with a signature" 200 "$(status "$URL/$pid.png?exp=$exp&sig=$sig")"
check "private ?direct with a signature" 200 "$(status "$URL/$pid?direct&exp=$exp&sig=$sig")"

# Password
protected=$(curl -sf "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: pw.png" \
  -H "X-Skljoc-Options: $opt_password" --data-binary @"$WORK/shot.png" "$URL/api/uploads")
wid=$(field id <<<"$protected")
check "password page asks" 401 "$(status "$URL/$wid")"
check "password raw hidden" 404 "$(status "$URL/$wid.png")"
check "wrong password" 401 "$(status --data-urlencode 'password=nope' "$URL/$wid")"
check "right password" 303 "$(status -c "$WORK/cookies" --data-urlencode 'password=čarobna reč' "$URL/$wid")"
check "page with the cookie" 200 "$(status -b "$WORK/cookies" "$URL/$wid")"
check "raw with the cookie" 200 "$(status -b "$WORK/cookies" "$URL/$wid.png")"

# One-time link
once=$(curl -sf "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: once.png" \
  -H "X-Skljoc-Options: $opt_burn" --data-binary @"$WORK/shot.png" "$URL/api/uploads")
oid=$(field id <<<"$once")
check "one-time: first view" 200 "$(status -A 'Mozilla/5.0' "$URL/$oid")"
sleep 1
check "one-time: second view" 410 "$(status -A 'Mozilla/5.0' "$URL/$oid")"

# Expiry, by changing options afterwards
check "options update" 200 "$(status "${auth[@]}" -X PATCH -H 'Content-Type: application/json' -d "$expiry_json" "$URL/api/uploads/$id")"
sleep 2
check "expired link" 410 "$(status "$URL/$id")"

# Multipart (two parts of 6 MB; parts need at least 5 MB except the last)
start=$(curl -sf "${auth[@]}" -X POST -H "Content-Type: video/mp4" -H "X-Skljoc-Filename: video.mp4" "$URL/api/uploads/multipart")
mid=$(field id <<<"$start")
check "multipart not visible yet" 404 "$(status "$URL/$mid")"
split -b 6291456 "$WORK/video.mp4" "$WORK/part-"
parts="["
n=1
for part in "$WORK"/part-*; do
  etag=$(curl -sf "${auth[@]}" -X PUT --data-binary @"$part" "$URL/api/uploads/multipart/$mid/$n" | field etag)
  parts+="{\"partNumber\":$n,\"etag\":\"$etag\"},"
  n=$((n + 1))
done
parts="${parts%,}]"
complete_json="{\"parts\":$parts}"
check "multipart complete" 201 "$(status "${auth[@]}" -X POST -H 'Content-Type: application/json' -d "$complete_json" "$URL/api/uploads/multipart/$mid/complete")"
check "multipart size" 12582912 "$(curl -s "${auth[@]}" "$URL/api/uploads/$mid" | field size)"
check "video seeks" 206 "$(status -H 'Range: bytes=1000-1999' "$URL/$mid.mp4")"

# Any kind of file
printf 'PK\003\004 not really a zip' > "$WORK/archive.zip"
zip_id=$(curl -sf "${auth[@]}" -H "Content-Type: application/zip" -H "X-Skljoc-Filename: Project%20files.zip" --data-binary @"$WORK/archive.zip" "$URL/api/uploads" | field id)
check "zip page is a download card" 1 "$(curl -s "$URL/$zip_id" | grep -c 'class="badge">ZIP<' || true)"
check "zip raw" 200 "$(status "$URL/$zip_id.zip")"
printf 'all:\n\techo hi\n' > "$WORK/Makefile"
make_id=$(curl -sf "${auth[@]}" -H "Content-Type: application/octet-stream" -H "X-Skljoc-Filename: Makefile" --data-binary @"$WORK/Makefile" "$URL/api/uploads" | field id)
check "no extension is fine" 200 "$(status "$URL/$make_id.bin")"
printf '<script>alert(1)</script>' > "$WORK/page.html"
html_id=$(curl -sf "${auth[@]}" -H "Content-Type: text/html" -H "X-Skljoc-Filename: page.html" --data-binary @"$WORK/page.html" "$URL/api/uploads" | field id)
html_csp=$(curl -s -D - -o /dev/null "$URL/$html_id.html" | grep -ci '^content-security-policy: sandbox' || true)
check "uploaded HTML runs sandboxed" 1 "$html_csp"
video_csp=$(curl -s -D - -o /dev/null "$URL/$mid.mp4" | grep -ci '^content-security-policy' || true)
check "videos play normally" 0 "$video_csp"

# Chosen link names
named_opts=$(options '{"slug":"offer-2026"}')
check "upload with a chosen name" 201 "$(status "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: offer.png" -H "X-Skljoc-Options: $named_opts" --data-binary @"$WORK/shot.png" "$URL/api/uploads")"
check "chosen name works" 200 "$(status "$URL/offer-2026")"
check "chosen name raw" 200 "$(status "$URL/offer-2026.png")"
check "chosen name is taken" 409 "$(status "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: offer.png" -H "X-Skljoc-Options: $named_opts" --data-binary @"$WORK/shot.png" "$URL/api/uploads")"
bad_opts=$(options '{"slug":"no spaces"}')
check "invalid chosen name" 400 "$(status "${auth[@]}" -H "Content-Type: image/png" -H "X-Skljoc-Filename: offer.png" -H "X-Skljoc-Options: $bad_opts" --data-binary @"$WORK/shot.png" "$URL/api/uploads")"
rename_json='{"slug":"offer-final"}'
check "rename" 200 "$(status "${auth[@]}" -X PATCH -H 'Content-Type: application/json' -d "$rename_json" "$URL/api/links/offer-2026")"
check "new name works" 200 "$(status "$URL/offer-final.png")"
check "old name is gone" 404 "$(status "$URL/offer-2026")"
taken_json='{"slug":"offer-final"}'
check "rename to a taken name" 409 "$(status "${auth[@]}" -X PATCH -H 'Content-Type: application/json' -d "$taken_json" "$URL/api/links/$zip_id")"

# Redirects (the URL shortener)
redirect_json='{"url":"https://example.com/a/long/page","slug":"cv"}'
check "redirect created" 201 "$(status "${auth[@]}" -H 'Content-Type: application/json' -d "$redirect_json" "$URL/api/links")"
check "slug taken" 409 "$(status "${auth[@]}" -H 'Content-Type: application/json' -d "$redirect_json" "$URL/api/links")"
check "redirect jumps" 302 "$(status -A 'Mozilla/5.0' "$URL/cv")"
check "redirect target" "https://example.com/a/long/page" "$(curl -s -o /dev/null -w '%{redirect_url}' "$URL/cv")"
check "bots follow but don't count" 302 "$(status -A 'Slackbot-LinkExpanding 1.0' "$URL/cv")"
sleep 1
check "clicks counted" 2 "$(curl -s "${auth[@]}" "$URL/api/links/cv" | field views)"
random_json='{"url":"https://example.com","password":"x"}'
rid=$(curl -sf "${auth[@]}" -H 'Content-Type: application/json' -d "$random_json" "$URL/api/links" | field id)
check "random slug" 5 "${#rid}"
check "password-protected redirect asks" 401 "$(status "$URL/$rid")"
bad_json='{"url":"javascript:alert(1)"}'
check "only http(s) targets" 400 "$(status "${auth[@]}" -H 'Content-Type: application/json' -d "$bad_json" "$URL/api/links")"
retarget_json='{"url":"https://example.org/new"}'
check "change the target" 200 "$(status "${auth[@]}" -X PATCH -H 'Content-Type: application/json' -d "$retarget_json" "$URL/api/links/cv")"
check "new target" "https://example.org/new" "$(curl -s -o /dev/null -w '%{redirect_url}' "$URL/cv")"
check "list redirects" 200 "$(status "${auth[@]}" "$URL/api/links")"
check "delete redirect" 200 "$(status "${auth[@]}" -X DELETE "$URL/api/links/cv")"
check "deleted redirect" 404 "$(status "$URL/cv")"

# Listing and deleting
check "list" 200 "$(status "${auth[@]}" "$URL/api/uploads")"
check "delete" 200 "$(status "${auth[@]}" -X DELETE "$URL/api/uploads/$mid")"
check "deleted is gone" 404 "$(status "$URL/$mid")"

if (( failures > 0 )); then
  echo "$failures failed"
  exit 1
fi
echo "All checks passed"
