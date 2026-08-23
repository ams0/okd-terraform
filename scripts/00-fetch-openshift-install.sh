#!/usr/bin/env bash
# Fetch (or update) the openshift-install binary for OKD-SCOS into .bin/.
#
# Default behavior: resolve the newest stable release and install it if the
# local binary is missing or older. The local binary is NEVER silently
# downgraded — if you already have something newer than the resolved release
# (e.g. you hand-dropped a build), it is left alone.
#
# Environment overrides:
#   OKD_VERSION            pin an exact release (e.g. "4.22.0-okd-scos.8").
#                          Enforced exactly: re-fetched if the local binary
#                          differs, including downgrades.
#   OKD_REPO               source repo (default: okd-project/okd)
#   OKD_SKIP_UPDATE_CHECK  =1 to keep an existing binary without contacting
#                          GitHub at all (offline / air-gapped use)
#   OKD_ALLOW_PRERELEASE   =1 to also consider ec (engineering candidate)
#                          builds such as 5.0.0-okd-scos.ec.7
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.bin"
INSTALLER="$BIN/openshift-install"

OKD_REPO="${OKD_REPO:-okd-project/okd}"
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

# `openshift-install version` prints "<path> <version>" on its first line.
installed_version() {
  [[ -x "$INSTALLER" ]] || return 1
  "$INSTALLER" version 2>/dev/null | head -1 | awk '{print $2}'
}

# Compare two OKD-SCOS versions. Exits 0 if $1 is strictly newer than $2.
# Ordering key: (major, minor, patch, 0 for ec / 1 for final, build). The ec
# rank sits below final so 5.0.0-okd-scos.ec.7 < 5.0.0-okd-scos.0, matching
# how OKD actually promotes releases.
version_gt() {
  A="$1" B="$2" python3 -c '
import os, re, sys
def key(tag):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)-okd-scos(\.ec)?\.(\d+)$", tag or "")
    if not m:
        return None
    maj, mnr, pat, ec, build = m.groups()
    return (int(maj), int(mnr), int(pat), 0 if ec else 1, int(build))
a, b = key(os.environ["A"]), key(os.environ["B"])
# Unparseable local version => treat remote as newer so we self-heal.
sys.exit(0 if a is not None and (b is None or a > b) else 1)
'
}

# Pick the highest-versioned release rather than trusting GitHub's "latest"
# flag: okd-project marks ec builds as prereleases, and the /releases/latest
# endpoint has historically pointed at an older stable branch than the newest
# one available.
resolve_latest() {
  api "https://api.github.com/repos/${OKD_REPO}/releases?per_page=100" \
    | ALLOW_PRE="${OKD_ALLOW_PRERELEASE:-}" python3 -c '
import json, os, re, sys
allow_pre = os.environ.get("ALLOW_PRE") == "1"
def key(tag):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)-okd-scos(\.ec)?\.(\d+)$", tag)
    if not m:
        return None
    maj, mnr, pat, ec, build = m.groups()
    return (int(maj), int(mnr), int(pat), 0 if ec else 1, int(build))
best, best_key = "", None
for r in json.load(sys.stdin):
    if r.get("draft"):
        continue
    if r.get("prerelease") and not allow_pre:
        continue
    k = key(r.get("tag_name", ""))
    if k and (best_key is None or k > best_key):
        best, best_key = r["tag_name"], k
print(best)
'
}

download_version() {
  local want="$1" url tmp
  url=$(api "https://api.github.com/repos/${OKD_REPO}/releases/tags/${want}" \
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

  if [[ -z "$url" ]]; then
    echo "FATAL: no openshift-install asset for ${OS_KEY}/${ARCH_KEY} in ${want}" >&2
    echo "       Browse: https://github.com/${OKD_REPO}/releases/tag/${want}" >&2
    echo "       Then drop the binary at ${INSTALLER} manually." >&2
    exit 1
  fi

  mkdir -p "$BIN"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  echo "==> Downloading $url"
  curl -fL --progress-bar "$url" -o "$tmp/oi.tgz"
  echo "==> Extracting → $INSTALLER"
  tar -xzf "$tmp/oi.tgz" -C "$tmp"
  [[ -f "$tmp/openshift-install" ]] || {
    echo "FATAL: tarball did not contain an 'openshift-install' binary at the top level" >&2
    exit 1
  }
  # Install atomically: a half-written binary next to a valid ignition set is a
  # nasty state to debug.
  mv "$tmp/openshift-install" "$INSTALLER.new"
  chmod +x "$INSTALLER.new"
  mv "$INSTALLER.new" "$INSTALLER"
}

have="$(installed_version || true)"

# Offline escape hatch: keep whatever is on disk.
if [[ -n "$have" && "${OKD_SKIP_UPDATE_CHECK:-}" == "1" ]]; then
  echo "==> openshift-install $have present, update check disabled (OKD_SKIP_UPDATE_CHECK=1)"
  exit 0
fi

# Explicit pin: enforce it exactly, in either direction.
if [[ -n "$OKD_VERSION" ]]; then
  if [[ "$have" == "$OKD_VERSION" ]]; then
    echo "==> openshift-install already at pinned $OKD_VERSION"
    exit 0
  fi
  echo "==> Pinned OKD_VERSION=$OKD_VERSION (have: ${have:-none}) → fetching"
  download_version "$OKD_VERSION"
  "$INSTALLER" version
  exit 0
fi

echo "==> Resolving newest release from github.com/${OKD_REPO}"
latest="$(resolve_latest || true)"
if [[ -z "$latest" ]]; then
  if [[ -n "$have" ]]; then
    echo "WARN: could not reach GitHub to check for updates; keeping $have" >&2
    exit 0
  fi
  echo "FATAL: could not resolve a release and no local binary exists." >&2
  echo "       Set OKD_VERSION explicitly. See https://github.com/${OKD_REPO}/releases" >&2
  exit 1
fi

if [[ -z "$have" ]]; then
  echo "==> No local binary → installing $latest"
  download_version "$latest"
elif version_gt "$latest" "$have"; then
  echo "==> Update available: $have → $latest"
  download_version "$latest"
else
  echo "==> openshift-install $have is up to date (newest release: $latest)"
  exit 0
fi

"$INSTALLER" version
