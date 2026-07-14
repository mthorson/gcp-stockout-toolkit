#!/usr/bin/env bash
# Opt-in sandbox integration test. This creates and then releases billable resources.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${RUN_LIVE_GCP_TESTS:-}" != 1 ]]; then
  echo "ERROR: set RUN_LIVE_GCP_TESTS=1 to acknowledge that this test creates billable GCP resources" >&2
  exit 2
fi
[[ $# -eq 2 ]] || {
  echo "Usage: RUN_LIVE_GCP_TESTS=1 tests/live_smoke.sh <capacity.conf> <reservations.conf>" >&2
  exit 2
}

CAPACITY_CONFIG="$1"
RESERVATIONS_CONFIG="$2"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="live-smoke-$STAMP"
LIVE_DIR="$ROOT/.live-tests/$STAMP"
SHARED_RECORD="$LIVE_DIR/shared.txt"
SPECIFIC_RECORD="$LIVE_DIR/specific.txt"
mkdir -p "$LIVE_DIR"

cleanup() {
  if [[ -f "$ROOT/.runs/$RUN_ID/winner.tfvars" ]]; then
    "$ROOT/release_capacity.sh" --run-id "$RUN_ID" --yes || true
  fi
  for record in "$SHARED_RECORD" "$SPECIFIC_RECORD"; do
    if [[ -f "$record" ]]; then
      "$ROOT/release_reservations.sh" --file "$record" --yes || true
    fi
  done
}
trap cleanup EXIT INT TERM

echo "Running preflight checks"
"$ROOT/grab_capacity.sh" --config "$CAPACITY_CONFIG" --run-id "$RUN_ID" --check-only
"$ROOT/grab_reservations.sh" --config "$RESERVATIONS_CONFIG" --check-only

echo "Testing one capacity attempt"
"$ROOT/grab_capacity.sh" --config "$CAPACITY_CONFIG" --run-id "$RUN_ID" \
  --delay 0 --max-delay 0 --max-attempts 1
"$ROOT/release_capacity.sh" --run-id "$RUN_ID" --yes

echo "Testing one shared reservation"
"$ROOT/grab_reservations.sh" --config "$RESERVATIONS_CONFIG" --specific=false \
  --count 1 --delay 0 --max-delay 0 --max-attempts 1 --record "$SHARED_RECORD"
"$ROOT/release_reservations.sh" --file "$SHARED_RECORD" --yes

echo "Testing one specific reservation"
"$ROOT/grab_reservations.sh" --config "$RESERVATIONS_CONFIG" --specific \
  --count 1 --delay 0 --max-delay 0 --max-attempts 1 --record "$SPECIFIC_RECORD"
"$ROOT/release_reservations.sh" --file "$SPECIFIC_RECORD" --yes

trap - EXIT INT TERM
echo "Live smoke test passed. Audit files remain in $LIVE_DIR"
