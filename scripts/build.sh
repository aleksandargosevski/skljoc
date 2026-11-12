#!/usr/bin/env bash
# Builds Skljoc.app into ./build and signs it.
#
# Options:
#   --run   restart the app after building
#   --zip   also create build/Skljoc-<version>.zip for a release
#
# Environment:
#   SKLJOC_VERSION        version written into Info.plist (e.g. 1.2.0)
#   SKLJOC_SIGN_IDENTITY  code signing identity (default: "Skljoc Dev")
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Skljoc"
APP="$ROOT/build/$APP_NAME.app"
PLIST="$ROOT/Resources/Info.plist"
IDENTITY="${SKLJOC_SIGN_IDENTITY:-Skljoc Dev}"
VERSION="${SKLJOC_VERSION:-}"

RUN=false
ZIP=false
for arg in "$@"; do
  case "$arg" in
    --run) RUN=true ;;
    --zip) ZIP=true ;;
    *) echo "Error: unknown option $arg (expected --run or --zip)" >&2; exit 1 ;;
  esac
done

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: SKLJOC_VERSION must look like 1.2.3, got \"$VERSION\"" >&2
  exit 1
fi

if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "Error: signing identity \"$IDENTITY\" not found. Run scripts/create-cert.sh first." >&2
  exit 1
fi

swift build -c release --package-path "$ROOT"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/MenuBarIcon.png" "$ROOT/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
# The Worker Škljoc deploys to the user's Cloudflare account from Settings → Upload.
mkdir -p "$APP/Contents/Resources/Worker"
cp -R "$ROOT/worker/src" "$ROOT/worker/migrations" "$APP/Contents/Resources/Worker/"

if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
# Keep the build copy out of Launch Services, so notifications and the Dock take name and icon
# from the installed app rather than from whichever copy macOS saw first.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

if $ZIP; then
  ZIP_PATH="$ROOT/build/$APP_NAME-${VERSION:-dev}.zip"
  rm -f "$ZIP_PATH"
  # Without these flags ditto stores metadata as ._* files, which plain unzip (used by Homebrew)
  # extracts into the bundle and thereby breaks the code signature.
  ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn "$APP" "$ZIP_PATH"
  echo "Created $ZIP_PATH"
fi

if $RUN; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  open "$APP"
  echo "Started $APP_NAME"
fi
