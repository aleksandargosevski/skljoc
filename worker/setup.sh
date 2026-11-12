#!/usr/bin/env bash
# Sets up the Škljoc Worker on your Cloudflare account from the terminal:
# creates (or reuses) the R2 bucket and D1 database, generates the upload token,
# deploys, and prints what to paste into Škljoc → Settings → Upload.
#
# Usage: worker/setup.sh [--bucket NAME] [--domain share.example.com]
#   --bucket  R2 bucket for uploads (default: skljoc). An existing bucket is reused.
#   --domain  serve the Worker on this hostname of a zone in your account.
set -euo pipefail

cd "$(dirname "$0")"
BUCKET="skljoc"
DOMAIN=""
DATABASE="skljoc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="${2:?--bucket needs a name}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain needs a hostname}"; shift 2 ;;
    *) echo "Error: unknown option $1" >&2; exit 1 ;;
  esac
done

main() {
  command -v npx >/dev/null || fail "Node.js is required (https://nodejs.org or brew install node)."
  step "Installing Wrangler"
  npm install --silent

  step "Checking your Cloudflare login"
  npx wrangler whoami >/dev/null 2>&1 || npx wrangler login

  step "R2 bucket \"$BUCKET\""
  if npx wrangler r2 bucket info "$BUCKET" >/dev/null 2>&1; then
    echo "Using the existing bucket."
  else
    npx wrangler r2 bucket create "$BUCKET"
  fi

  step "D1 database \"$DATABASE\""
  local database_id
  database_id="$(existing_database_id || true)"
  if [[ -z "$database_id" ]]; then
    database_id="$(npx wrangler d1 create "$DATABASE" 2>&1 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  fi
  [[ -n "$database_id" ]] || fail "Could not create or find the D1 database."

  step "Writing wrangler.jsonc"
  configure "$database_id"

  step "Upload token"
  local token
  token="$(openssl rand -hex 32)"
  printf '%s' "$token" | npx wrangler secret put UPLOAD_TOKEN >/dev/null 2>&1 || {
    # The secret can only be added to a Worker that exists, so deploy once first.
    npx wrangler deploy >/dev/null
    printf '%s' "$token" | npx wrangler secret put UPLOAD_TOKEN
  }

  step "Deploying"
  npm run deploy

  local address="${DOMAIN:+https://$DOMAIN}"
  if [[ -z "$address" ]]; then
    local subdomain
    subdomain="$(npx wrangler whoami 2>/dev/null | grep -oE '[a-z0-9-]+\.workers\.dev' | head -1 || true)"
    address="https://skljoc.${subdomain:-<your-subdomain>.workers.dev}"
  fi

  cat <<EOF

Done. In Škljoc → Settings → Upload, enter:

  Worker address:  $address
  Upload token:    $token

Keep the token somewhere safe; it is the only key to your uploads.
EOF
}

existing_database_id() {
  npx wrangler d1 list --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const db=JSON.parse(s).find(d=>d.name===process.argv[1]);if(db)console.log(db.uuid)})' "$DATABASE"
}

configure() {
  node - "$1" "$BUCKET" "$DOMAIN" <<'NODE'
const fs = require("fs");
const [databaseId, bucket, domain] = process.argv.slice(2);
let config = fs.readFileSync("wrangler.jsonc", "utf8");
config = config.replace(/"database_id": "[^"]*"/, `"database_id": "${databaseId}"`);
config = config.replace(/"bucket_name": "[^"]*"/, `"bucket_name": "${bucket}"`);
if (domain && !config.includes('"routes"')) {
  config = config.replace(/\n}\s*$/, `,\n  "routes": [{ "pattern": "${domain}", "custom_domain": true }]\n}\n`);
}
fs.writeFileSync("wrangler.jsonc", config);
NODE
}

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { echo "Error: $1" >&2; exit 1; }

main
