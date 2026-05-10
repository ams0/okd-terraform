#!/usr/bin/env bash
# Fetch the openshift-install binary for OKD-SCOS into .bin/. No-op if already
# present and executable. Override the release with OKD_VERSION (e.g.
# "4.19.0-okd-scos.16"); otherwise the latest tag at github.com/okd-project/okd-scos
# is used. Override the source with OKD_REPO (default: okd-project/okd-scos).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.bin"
INSTALLER="$BIN/openshift-install"

if [[ -x "$INSTALLER" ]]; then
  echo "==> $INSTALLER already present (skip). Delete it or set OKD_VERSION to re-fetch."
  exit 0
fi

OKD_REPO="${OKD_REPO:-okd-project/okd-scos}"
OKD_VERSION="${OKD_VERSION:-}"

case "$(uname -s)" in
  Darwin) OS_KEY="mac" ;;
  Linux)  OS_KEY="linux" ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH_KEY="arm64" ;;
  x86_64|amd64)  ARCH_KEY="amd64" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

api() { curl -fsSL "$@"; }

if [[ -z "$OKD_VERSION" ]]; then
  echo "==> Resolving latest tag from github.com/${OKD_REPO}"
  OKD_VERSION=$(api "https://api.github.com/repos/${OKD_REPO}/releases/latest" \
    | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  [[ -n "$OKD_VERSION" ]] || {
    echo "FATAL: could not resolve latest release. Set OKD_VERSION explicitly." >&2
    echo "       See https://github.com/${OKD_REPO}/releases" >&2
    exit 1
  }
fi
echo "==> Using version: $OKD_VERSION"

# Pick the openshift-install asset whose filename contains the right OS keyword
# and either the right arch keyword (arm64) or no arm64 (implicit amd64).
URL=$(api "https://api.github.com/repos/${OKD_REPO}/releases/tags/${OKD_VERSION}" \
  | sed -nE 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+openshift-install[^"]+\.tar\.gz)".*/\1/p' \
  | OS_KEY="$OS_KEY" ARCH_KEY="$ARCH_KEY" python3 -c '
import os, sys
os_key, arch_key = os.environ["OS_KEY"], os.environ["ARCH_KEY"]
def score(url):
    name = url.rsplit("/", 1)[-1].lower()
    if "openshift-install" not in name or os_key not in name:
        return -1
    if arch_key == "arm64" and "arm64" not in name: return -1
    if arch_key == "amd64" and "arm64"     in name: return -1
    return len(name)
candidates = [u.strip() for u in sys.stdin if u.strip()]
best = max(candidates, key=score, default="")
print(best if score(best) >= 0 else "")
')

if [[ -z "$URL" ]]; then
  echo "FATAL: no openshift-install asset for ${OS_KEY}/${ARCH_KEY} in ${OKD_VERSION}" >&2
  echo "       Browse: https://github.com/${OKD_REPO}/releases/tag/${OKD_VERSION}" >&2
  echo "       Then drop the binary at ${INSTALLER} manually." >&2
  exit 1
fi

mkdir -p "$BIN"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "==> Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/oi.tgz"
echo "==> Extracting → $INSTALLER"
tar -xzf "$TMP/oi.tgz" -C "$TMP"
[[ -f "$TMP/openshift-install" ]] || {
  echo "FATAL: tarball did not contain an 'openshift-install' binary at the top level" >&2
  exit 1
}
mv "$TMP/openshift-install" "$INSTALLER"
chmod +x "$INSTALLER"

"$INSTALLER" version
