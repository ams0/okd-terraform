#!/usr/bin/env bash
# Tear down the cluster. After this completes, the install/ ignition artifacts
# are kept on disk but are stale. The next `scripts/04-bringup.sh` will detect
# the empty terraform state and regenerate them automatically.
#
# Pass extra flags through, e.g. `scripts/05-teardown.sh -auto-approve`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform"
terraform destroy "$@"

echo
echo "Teardown complete. To recreate: $ROOT/scripts/04-bringup.sh"
