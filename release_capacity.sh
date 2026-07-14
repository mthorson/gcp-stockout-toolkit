#!/usr/bin/env bash
# Destroy the VM and state associated with one isolated capacity run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

usage() {
  echo "Usage: ./release_capacity.sh --run-id <id> [--yes]"
}

RUN_ID=""
YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) [[ $# -ge 2 ]] || { echo "ERROR: --run-id requires a value" >&2; exit 2; }; RUN_ID="$2"; shift 2 ;;
    --run-id=*) RUN_ID="${1#*=}"; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_ID" ]] || { echo "ERROR: --run-id is required" >&2; exit 2; }
[[ "$RUN_ID" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "ERROR: invalid run ID '$RUN_ID'" >&2; exit 2; }
command -v terraform >/dev/null || { echo "ERROR: terraform not found on PATH" >&2; exit 1; }

RUN_DIR="$ROOT/.runs/$RUN_ID"
WINNER_VARS="$RUN_DIR/winner.tfvars"
export TF_DATA_DIR="$RUN_DIR/.terraform"
[[ -d "$TF_DATA_DIR" && -f "$WINNER_VARS" ]] || {
  echo "ERROR: no completed capacity run found for '$RUN_ID'" >&2
  exit 1
}
LOCK_DIR="$RUN_DIR/.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: run '$RUN_ID' is active or has a stale lock" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if ! terraform state list 2>/dev/null | grep -qx 'google_compute_instance.grab'; then
  echo "No managed instance remains for run '$RUN_ID'."
  exit 0
fi

echo "Resources to release for run '$RUN_ID':"
terraform state show -no-color google_compute_instance.grab | sed -n '/^resource/,/^[[:space:]]*}/p' | sed 's/^/  /'
if [[ "$YES" == false ]]; then
  read -r -p "Destroy this instance? [y/N] " answer || answer=""
  [[ "$answer" == y || "$answer" == Y ]] || { echo "Cancelled."; exit 1; }
fi

terraform destroy -auto-approve -no-color -input=false -var-file="$WINNER_VARS"
if terraform state list 2>/dev/null | grep -q .; then
  echo "ERROR: Terraform state is not empty; preserving $RUN_DIR for inspection" >&2
  exit 1
fi
rm -rf "$RUN_DIR"
echo "Released run '$RUN_ID' and removed its local run data."
