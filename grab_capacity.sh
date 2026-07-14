#!/usr/bin/env bash
# Poll GCP Compute Engine for one on-demand VM and leave the first success running.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
source "$ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./grab_capacity.sh [--config <file>] --machine-types <csv> --zones <csv> \
      --delay <seconds> [--max-delay <seconds>] [--max-attempts <n>] \
      [--run-id <id>] [--json-log <path>] [--check-only]

  --config         key=value config file; command-line flags override it
  --machine-types  comma-separated, e.g. "n2-highmem-128,c3-highmem-176"
  --zones          comma-separated full zones, e.g. "us-central1-a,us-central1-b"
  --delay          initial retry delay in seconds
  --max-delay      maximum exponential backoff delay; default 900
  --max-attempts   optional; 0 (default) means retry forever
  --run-id         isolated run name; default grab-<timestamp>
  --json-log       JSON Lines attempt log; default .runs/<run-id>/attempts.jsonl
  --check-only     validate configuration and GCP targets without creating resources
  -h, --help       show this help
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
MAX_DELAY="900"
MAX_ATTEMPTS="0"
RUN_ID=""
JSON_LOG=""
CHECK_ONLY=false
CONFIG_FILE=""

set_config_value() {
  local key="$1" value="$2" source="$3"
  case "$key" in
    machine_types) MACHINE_TYPES="$value" ;;
    zones) ZONES_CSV="$value" ;;
    delay) DELAY="$value" ;;
    max_delay) MAX_DELAY="$value" ;;
    max_attempts) MAX_ATTEMPTS="$value" ;;
    run_id) RUN_ID="$value" ;;
    json_log) JSON_LOG="$value" ;;
    check_only) require_boolean "$source:check_only" "$value"; CHECK_ONLY="$value" ;;
    *) echo "ERROR: unknown capacity config key '$key' at $source" >&2; exit 2 ;;
  esac
}

find_config_argument "$@"
[[ -z "$CONFIG_FILE" ]] || load_config_file "$CONFIG_FILE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)          need_value "$@"; shift 2 ;;
    --config=*)        shift ;;
    --machine-types)   need_value "$@"; MACHINE_TYPES="$2"; shift 2 ;;
    --machine-types=*) MACHINE_TYPES="${1#*=}"; shift ;;
    --zones)           need_value "$@"; ZONES_CSV="$2"; shift 2 ;;
    --zones=*)         ZONES_CSV="${1#*=}"; shift ;;
    --delay)           need_value "$@"; DELAY="$2"; shift 2 ;;
    --delay=*)         DELAY="${1#*=}"; shift ;;
    --max-delay)       need_value "$@"; MAX_DELAY="$2"; shift 2 ;;
    --max-delay=*)     MAX_DELAY="${1#*=}"; shift ;;
    --max-attempts)    need_value "$@"; MAX_ATTEMPTS="$2"; shift 2 ;;
    --max-attempts=*)  MAX_ATTEMPTS="${1#*=}"; shift ;;
    --run-id)          need_value "$@"; RUN_ID="$2"; shift 2 ;;
    --run-id=*)        RUN_ID="${1#*=}"; shift ;;
    --json-log)        need_value "$@"; JSON_LOG="$2"; shift 2 ;;
    --json-log=*)      JSON_LOG="${1#*=}"; shift ;;
    --check-only)      CHECK_ONLY=true; shift ;;
    --check-only=*)    require_boolean "--check-only" "${1#*=}"; CHECK_ONLY="${1#*=}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; echo; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MACHINE_TYPES" ]] || { echo "ERROR: --machine-types is required" >&2; exit 2; }
[[ -n "$ZONES_CSV" ]]     || { echo "ERROR: --zones is required" >&2; exit 2; }
[[ -n "$DELAY" ]]         || { echo "ERROR: --delay is required" >&2; exit 2; }
[[ "$DELAY" =~ ^[0-9]+$ ]]        || { echo "ERROR: --delay must be integer seconds, got '$DELAY'" >&2; exit 2; }
[[ "$MAX_DELAY" =~ ^[0-9]+$ ]]    || { echo "ERROR: --max-delay must be an integer" >&2; exit 2; }
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || { echo "ERROR: --max-attempts must be an integer" >&2; exit 2; }
[[ "$MAX_DELAY" -ge "$DELAY" ]]  || { echo "ERROR: --max-delay must be at least --delay" >&2; exit 2; }
command -v terraform >/dev/null || { echo "ERROR: terraform not found on PATH" >&2; exit 1; }

[[ -n "$RUN_ID" ]] || RUN_ID="grab-$(date +%Y%m%d-%H%M%S)"
[[ "$RUN_ID" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
  echo "ERROR: --run-id must be 1-32 lowercase letters, digits, or hyphens" >&2
  exit 2
}

IFS=',' read -r -a MTYPES <<< "$MACHINE_TYPES"
IFS=',' read -r -a ZONES <<< "$ZONES_CSV"
for mt in "${MTYPES[@]}"; do
  [[ "$mt" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid machine type '$mt'" >&2; exit 2; }
done
for zone in "${ZONES[@]}"; do
  [[ "$zone" =~ ^[a-z][a-z0-9-]*-[a-z]$ ]] || { echo "ERROR: invalid zone '$zone'" >&2; exit 2; }
done

RUN_DIR="$ROOT/.runs/$RUN_ID"
TF_DATA_DIR="$RUN_DIR/.terraform"
STATE_PATH="$RUN_DIR/terraform.tfstate"
WINNER_VARS="$RUN_DIR/winner.tfvars"
LOCK_DIR="$RUN_DIR/.lock"
mkdir -p "$RUN_DIR"
export TF_DATA_DIR
[[ -n "$JSON_LOG" ]] || JSON_LOG="$RUN_DIR/attempts.jsonl"
[[ "$JSON_LOG" == /* ]] || JSON_LOG="$ROOT/$JSON_LOG"
[[ -d "$(dirname "$JSON_LOG")" ]] || { echo "ERROR: JSON log directory does not exist: $(dirname "$JSON_LOG")" >&2; exit 2; }

LOG="$(mktemp)"
LOCK_ACQUIRED=0
cleanup() {
  rm -f "$LOG"
  [[ $LOCK_ACQUIRED -eq 0 ]] || rmdir "$LOCK_DIR" 2>/dev/null || true
}
interrupt() {
  echo
  echo "Interrupted. Inspect run '$RUN_ID' before retrying or releasing it."
  exit 130
}
trap cleanup EXIT
trap interrupt INT TERM

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: run '$RUN_ID' is already active or has a stale lock" >&2
  echo "Remove $LOCK_DIR only after confirming no other process uses it." >&2
  exit 1
fi
LOCK_ACQUIRED=1

if [[ ! -d "$TF_DATA_DIR" ]]; then
  if ! terraform init -input=false -no-color -backend-config="path=$STATE_PATH"; then
    echo "ERROR: terraform init failed" >&2
    exit 1
  fi
fi

if terraform state list 2>/dev/null | grep -qx 'google_compute_instance.grab'; then
  echo "ERROR: run '$RUN_ID' already manages a grabbed instance." >&2
  echo "Release it with './release_capacity.sh --run-id $RUN_ID' before reusing this ID." >&2
  exit 1
fi

run_preflight() {
  local project mt zone region has_subnet failed=0
  echo "Running read-only preflight checks"
  terraform validate -no-color || return 1
  command -v gcloud >/dev/null || {
    echo "ERROR: gcloud is required for --check-only target validation" >&2
    return 1
  }
  project="$(terraform console -no-color 2>/dev/null <<< 'var.project_id' | tr -d '"')"
  [[ -n "$project" ]] || { echo "ERROR: could not read project_id from Terraform variables" >&2; return 1; }
  gcloud projects describe "$project" --format='value(projectId)' >/dev/null || return 1
  for zone in "${ZONES[@]}"; do
    region="${zone%-*}"
    has_subnet="$(terraform console -no-color 2>/dev/null <<< "contains(keys(var.subnetworks), \"$region\")")"
    if [[ "$has_subnet" == true ]]; then
      echo "  OK subnet mapping for $region"
    else
      echo "  FAIL no subnet mapping for $region" >&2
      failed=1
    fi
    for mt in "${MTYPES[@]}"; do
      if gcloud compute machine-types describe "$mt" --zone "$zone" --project "$project" --format='value(name)' >/dev/null 2>&1; then
        echo "  OK $mt in $zone"
      else
        echo "  FAIL $mt in $zone" >&2
        failed=1
      fi
    done
  done
  echo "Terraform credential validity, IAM create permission, quota headroom, Cloud NAT, and live capacity require environment-specific verification."
  [[ $failed -eq 0 ]]
}

if [[ "$CHECK_ONLY" == true ]]; then
  run_preflight
  exit $?
fi

TF_APPLY=(terraform apply -auto-approve -no-color -input=false -lock-timeout=120s -compact-warnings)
TOTAL_COMBOS=$(( ${#MTYPES[@]} * ${#ZONES[@]} ))
ts() { date '+%Y-%m-%d %H:%M:%S'; }

echo "Polling for capacity"
echo "  run ID        : $RUN_ID"
echo "  machine types : ${MTYPES[*]}"
echo "  zones         : ${ZONES[*]}"
echo "  retry delay   : ${DELAY}s initial, ${MAX_DELAY}s maximum"
echo "  max attempts  : $([[ "$MAX_ATTEMPTS" -eq 0 ]] && echo unlimited || echo "$MAX_ATTEMPTS")"
echo "  attempt log   : $JSON_LOG"
echo "On first success the instance is LEFT RUNNING. Ctrl-C to stop."
echo

attempt=0
blocked_in_row=0
failures=0
while true; do
  for mt in "${MTYPES[@]}"; do
    for zone in "${ZONES[@]}"; do
      attempt=$((attempt + 1))
      printf '[%s] attempt %-4d %-18s %-16s ... ' "$(ts)" "$attempt" "$mt" "$zone"

      "${TF_APPLY[@]}" -var "machine_type=$mt" -var "zone=$zone" -var "run_id=$RUN_ID" >"$LOG" 2>&1
      rc=$?

      if terraform state list 2>/dev/null | grep -qx 'google_compute_instance.grab'; then
        if [[ $rc -ne 0 ]]; then
          echo "STATE PRESENT"
          write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" state_present
          printf 'machine_type = "%s"\nzone = "%s"\nrun_id = "%s"\n' "$mt" "$zone" "$RUN_ID" > "$WINNER_VARS"
          echo "Terraform returned an error but recorded an instance in state. Stopping"
          echo "to avoid replacing possible secured capacity. Inspect it with:"
          echo "  TF_DATA_DIR=$TF_DATA_DIR terraform state show google_compute_instance.grab"
          echo "Release it with './release_capacity.sh --run-id $RUN_ID' if it exists."
          exit 1
        fi

        printf 'machine_type = "%s"\nzone = "%s"\nrun_id = "%s"\n' "$mt" "$zone" "$RUN_ID" > "$WINNER_VARS"
        echo "GOT IT"
        write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" success
        echo
        echo "Secured capacity after $attempt attempt(s):"
        terraform output 2>/dev/null | sed 's/^/  /'
        echo
        echo "The instance is LEFT RUNNING. Release it when done with:"
        echo "  ./release_capacity.sh --run-id $RUN_ID"
        exit 0
      fi

      failures=$((failures + 1))
      if grep -qiE "does not have enough resources|ZONE_RESOURCE_POOL_EXHAUSTED|stockout" "$LOG"; then
        echo "STOCKOUT"
        write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" stockout
        blocked_in_row=0
      elif grep -qiE "quota|QUOTA_EXCEEDED" "$LOG"; then
        echo "QUOTA (needs an increase)"
        write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" quota
        blocked_in_row=$((blocked_in_row + 1))
      elif grep -qiE "rate.?limit|RESOURCE_OPERATION_RATE_EXCEEDED|429" "$LOG"; then
        echo "RATE LIMIT"
        write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" rate_limit
        blocked_in_row=0
      else
        echo "ERROR:"
        tail -4 "$LOG" | sed 's/^/      /'
        write_attempt_log "$JSON_LOG" capacity "$attempt" "$zone" "$mt" error
        blocked_in_row=$((blocked_in_row + 1))
      fi

      if [[ $blocked_in_row -ge $TOTAL_COMBOS ]]; then
        echo
        echo "Every target hit quota or a permanent error for a full cycle. Stopping."
        exit 1
      fi
      if [[ "$MAX_ATTEMPTS" -gt 0 && "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
        echo
        echo "Reached max attempts ($MAX_ATTEMPTS) without capacity. Nothing was created."
        exit 1
      fi
      sleep_after_failure "$DELAY" "$MAX_DELAY" "$failures"
    done
  done
done
