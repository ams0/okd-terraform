#!/usr/bin/env bash
# Self-contained: download, verify, decompress, and upload the SCOS Azure VHD
# to a storage account.
#
# Usage:
#   ./scripts/03-upload-vhd.sh <storage_account_name>
#
# Prerequisites on the running machine:
#   - az CLI (logged in via `az login`; the principal needs Storage Blob Data
#     Contributor on the storage account, or the subscription Contributor role)
#   - azcopy v10+
#   - curl, gunzip, shasum
#   - ~17 GB free disk space in $WORK
#
# Environment overrides:
#   WORK             scratch dir (default /tmp/okd-fcos)
#   SKIP_DOWNLOAD=1  skip download/decompress; expect $WORK/scos-azure.vhd
set -euo pipefail

SA="${1:-}"
[[ -n "$SA" ]] || { echo "usage: $0 <storage_account_name>" >&2; exit 2; }

WORK="${WORK:-/tmp/okd-fcos}"
RELEASE="10.0.20251103-0"
URL="https://rhcos.mirror.openshift.com/art/storage/prod/streams/c10s/builds/${RELEASE}/x86_64/scos-${RELEASE}-azure.x86_64.vhd.gz"
SHA_GZ="8de591c6914b0aa12615169a60879d387807003c45dc82234057d42fd0513161"
SHA_VHD="d93db396d4ada35d64a3201a1393ddb663c966df82e15e78841eadd9cda7001b"

mkdir -p "$WORK"
cd "$WORK"

if [[ -z "${SKIP_DOWNLOAD:-}" ]]; then
  if [[ ! -f scos-azure.vhd ]]; then
    if [[ ! -f scos-azure.vhd.gz ]]; then
      echo "==> Downloading SCOS VHD (${RELEASE}, ~966 MB)..."
      curl -fL --progress-bar -o scos-azure.vhd.gz "$URL"
    fi
    echo "==> Verifying compressed checksum"
    echo "$SHA_GZ  scos-azure.vhd.gz" | shasum -a 256 -c
    echo "==> Decompressing (~16 GB)"
    gunzip -k scos-azure.vhd.gz
  fi
  echo "==> Verifying VHD checksum"
  echo "$SHA_VHD  scos-azure.vhd" | shasum -a 256 -c
fi

[[ -f scos-azure.vhd ]] || { echo "scos-azure.vhd not found in $WORK" >&2; exit 1; }

DEST="https://${SA}.blob.core.windows.net/vhd/scos.vhd"
echo "==> Uploading to ${DEST} via azcopy (PageBlob, parallel)"
AZCOPY_AUTO_LOGIN_TYPE=AZCLI azcopy copy \
  "$WORK/scos-azure.vhd" \
  "$DEST" \
  --blob-type=PageBlob \
  --log-level=WARNING

echo
echo "Upload complete: ${DEST}"
echo "Now run: terraform apply"
