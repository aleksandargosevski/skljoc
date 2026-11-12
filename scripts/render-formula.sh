#!/usr/bin/env bash
# Prints the Homebrew formula for a released version.
# Usage: scripts/render-formula.sh <version> <sha256 of Skljoc-<version>.zip>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <sha256>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"
REPOSITORY="aleksandargosevski/skljoc"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must look like 1.2.3, got \"$VERSION\"" >&2
  exit 1
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Error: sha256 must be 64 lowercase hex characters" >&2
  exit 1
fi

cat <<EOF
class Skljoc < Formula
  desc "Screenshots with a floating preview and a quick annotation editor"
  homepage "https://github.com/${REPOSITORY}"
  url "https://github.com/${REPOSITORY}/releases/download/v${VERSION}/Skljoc-${VERSION}.zip"
  sha256 "${SHA256}"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    # Homebrew enters an archive's single top-level directory, which here is Skljoc.app itself.
    source = File.directory?("Contents") ? "." : "Skljoc.app"
    (prefix/"Skljoc.app").install Dir["#{source}/*"]
  end

  service do
    run [opt_prefix/"Skljoc.app/Contents/MacOS/Skljoc"]
    keep_alive crashed: true
    process_type :interactive
  end

  def caveats
    <<~EOS
      Start Škljoc now and at every login:
        brew services start skljoc

      Then allow Škljoc in System Settings → Privacy & Security → Screen & System Audio Recording,
      and turn off the macOS screenshot shortcuts (Keyboard → Keyboard Shortcuts → Screenshots)
      so ⌘⇧3, ⌘⇧4 and ⌘⇧5 reach Škljoc.
    EOS
  end

  test do
    assert_path_exists prefix/"Skljoc.app/Contents/MacOS/Skljoc"
  end
end
EOF
