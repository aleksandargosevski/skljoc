#!/usr/bin/env bash
# Updates an already set up Worker: applies new database migrations and deploys the code.
# The upload token, bucket and domain stay as they are.
# Needs wrangler.local.jsonc from setup.sh; copy it over to deploy from another Mac.
#
# Usage: worker/deploy.sh
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="wrangler.local.jsonc"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: $CONFIG not found. Run ./setup.sh once, or copy $CONFIG from the Mac where you did." >&2
  exit 1
fi
command -v npx >/dev/null || { echo "Error: Node.js is required (brew install node)." >&2; exit 1; }

npm install --silent
npx wrangler whoami >/dev/null 2>&1 || npx wrangler login
npx wrangler d1 migrations apply DB --remote --config "$CONFIG"
npx wrangler deploy --config "$CONFIG"
