#!/usr/bin/env bash
# Sets up the Škljoc Worker on your Cloudflare account from the terminal:
# creates (or reuses) the R2 bucket and D1 database, generates the upload token,
# deploys, and tells you what to paste into Škljoc → Settings → Upload.
# Your settings go to wrangler.local.jsonc (not committed); wrangler.jsonc stays a template.
#
# Usage: worker/setup.sh [--bucket NAME] [--domain share.example.com] [--new-token]
#   --bucket     R2 bucket for uploads (default: skljoc). An existing bucket is reused.
#   --domain     serve the Worker on this hostname of a zone in your account.
#   --new-token  replace the upload token. Without it, a Worker that already has one keeps it,
#                so every Mac using it keeps working.
# Later updates of the Worker only need worker/deploy.sh.
set -euo pipefail

cd "$(dirname "$0")"
BUCKET="skljoc"
DOMAIN=""
NEW_TOKEN=false
DATABASE="skljoc"
CONFIG="wrangler.local.jsonc"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="${2:?--bucket needs a name}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain needs a hostname}"; shift 2 ;;
    --new-token) NEW_TOKEN=true; shift ;;
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

  step "Writing $CONFIG"
  configure "$database_id"

  step "Deploying"
  npx wrangler d1 migrations apply DB --remote --config "$CONFIG"
  npx wrangler deploy --config "$CONFIG"

  step "Upload token"
  local token=""
  if ! $NEW_TOKEN && has_token; then
    echo "Keeping the existing token (pass --new-token to replace it)."
  else
    token="$(openssl rand -hex 32)"
    printf '%s' "$token" | npx wrangler secret put UPLOAD_TOKEN --config "$CONFIG" >/dev/null
  fi

  local address="${DOMAIN:+https://$DOMAIN}"
  if [[ -z "$address" ]]; then
    local subdomain
    subdomain="$(npx wrangler whoami 2>/dev/null | grep -oE '[a-z0-9-]+\.workers\.dev' | head -1 || true)"
    address="https://skljoc.${subdomain:-<your-subdomain>.workers.dev}"
  fi

  local shown="the one you already use (Škljoc → Settings → Upload → Copy Token)"
  if [[ -n "$token" ]]; then
    shown="$token"
    if command -v pbcopy >/dev/null; then
      printf '%s' "$token" | pbcopy
      shown="(copied to the clipboard)"
    fi
  fi
  cat <<EOF

Done. In Škljoc → Settings → Upload, enter:

  Worker address:  $address
  Upload token:    $shown

Keep the token somewhere safe; it is the only key to your uploads.
Keep $CONFIG too (it isn't committed): with it, worker/deploy.sh updates the Worker from any Mac.
EOF
}

has_token() {
  npx wrangler secret list --config "$CONFIG" 2>/dev/null | grep -q '"UPLOAD_TOKEN"'
}

existing_database_id() {
  npx wrangler d1 list --json 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const db=JSON.parse(s).find(d=>d.name===process.argv[1]);if(db)console.log(db.uuid)})' "$DATABASE"
}

configure() {
  node - "$1" "$BUCKET" "$DOMAIN" <<'NODE'
const fs = require("fs");
const [databaseId, bucket, domain] = process.argv.slice(2);
const target = "wrangler.local.jsonc";
let config = fs.readFileSync(fs.existsSync(target) ? target : "wrangler.jsonc", "utf8");
config = config.replace(/"database_id": "[^"]*"/, `"database_id": "${databaseId}"`);
config = config.replace(/"bucket_name": "[^"]*"/, `"bucket_name": "${bucket}"`);
if (domain && !config.includes('"routes"')) {
  config = config.replace(/\n}\s*$/, `,\n  "routes": [{ "pattern": "${domain}", "custom_domain": true }]\n}\n`);
}
fs.writeFileSync(target, config);
NODE
}

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { echo "Error: $1" >&2; exit 1; }

main
