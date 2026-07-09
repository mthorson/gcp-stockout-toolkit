#!/usr/bin/env bash
# grab_capacity.sh: poll GCP Compute Engine for on-demand capacity and grab it.
#
# Repeatedly attempts to create ONE instance across the given machine types x zones
# until one succeeds, sleeping --delay between attempts. On the first success the
# instance is LEFT RUNNING (the whole point: secure capacity the moment a STOCKOUT
# clears) and the script exits. Ctrl-C to stop early.
#
# Prerequisites:
#   - terraform >= 1.5 on PATH
#   - Authenticated: `gcloud auth application-default login` (or a service account)
#   - terraform.tfvars filled in (see terraform.tfvars.example), then `terraform init`
#
# Usage:
#   ./grab_capacity.sh --machine-types <csv> --zones <csv> --delay <seconds> [--max-attempts <n>]
#
#     --machine-types  comma-separated, e.g. "n2-highmem-128,c3-highmem-176"
#     --zones          comma-separated full zones, e.g. "us-central1-a,us-central1-b"
#     --delay          integer seconds slept between attempts
#     --max-attempts   optional; 0 (default) = retry forever
#     -h, --help       show this help
#
# Example (chase the target across every us-central1 zone, every 2 min):
#   ./grab_capacity.sh --machine-types n2-highmem-128 \
#       --zones us-central1-a,us-central1-b,us-central1-c,us-central1-f --delay 120
set -uo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage:
  ./grab_capacity.sh --machine-types <csv> --zones <csv> --delay <seconds> [--max-attempts <n>]

  --machine-types  comma-separated, e.g. "n2-highmem-128,c3-highmem-176"
  --zones          comma-separated full zones, e.g. "us-central1-a,us-central1-b"
  --delay          integer seconds slept between attempts
  --max-attempts   optional; 0 (default) = retry forever
  -h, --help       show this help

Example:
  ./grab_capacity.sh --machine-types n2-highmem-128 \
      --zones us-central1-a,us-central1-b,us-central1-c,us-central1-f --delay 120
EOF
}

need_value() {
  if [[ $# -lt 2 || "$2" == --* ]]; then
    echo "ERROR: $1 requires a value" >&2
    exit 2
  fi
}

MACHINE_TYPES=""
ZONES_CSV=""
DELAY=""
MAX_ATTEMPTS="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine-types)   need_value "$@"; MACHINE_TYPES="$2"; shift 2 ;;
    --machine-types=*) MACHINE_TYPES="${1#*=}"; shift ;;
    --zones)           need_value "$@"; ZONES_CSV="$2"; shift 2 ;;
    --zones=*)         ZONES_CSV="${1#*=}"; shift ;;
    --delay)           need_value "$@"; DELAY="$2"; shift 2 ;;
    --delay=*)         DELAY="${1#*=}"; shift ;;
    --max-attempts)    need_value "$@"; MAX_ATTEMPTS="$2"; shift 2 ;;
    --max-attempts=*)  MAX_ATTEMPTS="${1#*=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; echo; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MACHINE_TYPES" ]] || { echo "ERROR: --machine-types is required" >&2; exit 2; }
[[ -n "$ZONES_CSV" ]]     || { echo "ERROR: --zones is required" >&2; exit 2; }
[[ -n "$DELAY" ]]         || { echo "ERROR: --delay is required" >&2; exit 2; }
[[ "$DELAY" =~ ^[0-9]+$ ]]        || { echo "ERROR: --delay must be integer seconds, got '$DELAY'" >&2; exit 2; }
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || { echo "ERROR: --max-attempts must be an integer" >&2; exit 2; }
command -v terraform >/dev/null   || { echo "ERROR: terraform not found on PATH" >&2; exit 1; }

IFS=',' read -r -a MTYPES <<< "$MACHINE_TYPES"
IFS=',' read -r -a ZONES  <<< "$ZONES_CSV"

# Lean, fast applies: skip state refresh (state is trivially small), tolerate a
# brief lock, and keep warnings compact.
TF_APPLY=(terraform apply -auto-approve -no-color -input=false -refresh=false -lock-timeout=120s -compact-warnings)

LOG="$(mktemp)"
TOTAL_COMBOS=$(( ${#MTYPES[@]} * ${#ZONES[@]} ))
ts() { date '+%Y-%m-%d %H:%M:%S'; }

trap 'echo; echo "Interrupted. Failed attempts create nothing; a grabbed instance (if any) is left running."; rm -f "$LOG"; exit 130' INT TERM

[[ -d .terraform ]] || terraform init -input=false -no-color >/dev/null

echo "Polling for capacity"
echo "  machine types : ${MTYPES[*]}"
echo "  zones         : ${ZONES[*]}"
echo "  delay         : ${DELAY}s between attempts"
echo "  max attempts  : $([[ "$MAX_ATTEMPTS" -eq 0 ]] && echo unlimited || echo "$MAX_ATTEMPTS")"
echo "On first success the instance is LEFT RUNNING. Ctrl-C to stop."
echo

attempt=0
blocked_in_row=0
while true; do
  for mt in "${MTYPES[@]}"; do
    for zone in "${ZONES[@]}"; do
      attempt=$((attempt + 1))
      printf '[%s] attempt %-4d %-18s %-16s ... ' "$(ts)" "$attempt" "$mt" "$zone"

      "${TF_APPLY[@]}" -var "machine_type=$mt" -var "zone=$zone" >"$LOG" 2>&1
      rc=$?

      if [[ $rc -eq 0 ]] && terraform state list 2>/dev/null | grep -q 'google_compute_instance.grab'; then
        # Persist the winning target so a var-less `terraform destroy` works later.
        cat > winner.auto.tfvars <<EOF
machine_type = "$mt"
zone         = "$zone"
EOF
        echo "GOT IT"
        echo
        echo "Secured capacity after $attempt attempt(s):"
        terraform output 2>/dev/null | sed 's/^/  /'
        echo
        echo "The instance is LEFT RUNNING. Release it when done with:"
        echo "  terraform destroy -auto-approve   # then: rm -f winner.auto.tfvars"
        rm -f "$LOG"
        exit 0
      fi

      if grep -qiE "does not have enough resources|ZONE_RESOURCE_POOL_EXHAUSTED|stockout" "$LOG"; then
        echo "STOCKOUT"
        blocked_in_row=0
      elif grep -qiE "quota|QUOTA_EXCEEDED" "$LOG"; then
        echo "QUOTA (needs an increase)"
        blocked_in_row=$((blocked_in_row + 1))
      else
        echo "ERROR:"
        tail -4 "$LOG" | sed 's/^/      /'
        blocked_in_row=$((blocked_in_row + 1))
      fi

      if [[ $blocked_in_row -ge $TOTAL_COMBOS ]]; then
        echo
        echo "Every target hit quota or errored for a full cycle. This looks like a"
        echo "configuration, permission, or quota problem, not a capacity one."
        echo "Stopping so you can fix it and re-run."
        rm -f "$LOG"
        exit 1
      fi

      if [[ "$MAX_ATTEMPTS" -gt 0 && "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo
        echo "Reached max attempts ($MAX_ATTEMPTS) without capacity. Nothing was created."
        rm -f "$LOG"
        exit 1
      fi

      sleep "$DELAY"
    done
  done
done
