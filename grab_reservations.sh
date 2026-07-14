#!/usr/bin/env bash
# Accumulate single-VM Compute Engine reservations across a region.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || exit 1
source "$ROOT/lib/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./grab_reservations.sh [--config <file>] --machine-type <type> --region <region> \
      --delay <seconds> --count <n> [--max-delay <seconds>] [--max-attempts <n>] [--project <id>] \
      [--zones <csv>] [--specific] [--record <path>] [--json-log <path>] [--check-only]

  --config        key=value config file; command-line flags override it
  --machine-type  e.g. n2-highmem-128
  --region        e.g. us-central1
  --delay         initial retry delay in seconds
  --max-delay     maximum exponential backoff delay; default 900
  --max-attempts  optional; 0 (default) means retry until the count is reached
  --count         number of single-VM reservations to secure
  --project       defaults to the active gcloud project
  --zones         restrict attempts to a comma-separated list in the region
  --specific      require VMs to target each reservation by name
  --record        reservation record path; default reservations-<timestamp>.txt
  --json-log      JSON Lines attempt log; default reservations-<timestamp>.jsonl
  --check-only    validate configuration and targets without creating reservations
  -h, --help      show this help
EOF
}

need_value() {
  if [[ $# -lt 2 || "$2" == --* ]]; then
    echo "ERROR: $1 requires a value" >&2
    exit 2
  fi
}

MACHINE_TYPE=""
REGION=""
DELAY=""
MAX_DELAY="900"
MAX_ATTEMPTS="0"
TARGET=""
PROJECT=""
ZONES_CSV=""
SPECIFIC=false
RECORD=""
JSON_LOG=""
CHECK_ONLY=false
CONFIG_FILE=""

set_config_value() {
  local key="$1" value="$2" source="$3"
  case "$key" in
    machine_type) MACHINE_TYPE="$value" ;;
    region) REGION="$value" ;;
    delay) DELAY="$value" ;;
    max_delay) MAX_DELAY="$value" ;;
    max_attempts) MAX_ATTEMPTS="$value" ;;
    count) TARGET="$value" ;;
    project) PROJECT="$value" ;;
    zones) ZONES_CSV="$value" ;;
    specific) require_boolean "$source:specific" "$value"; SPECIFIC="$value" ;;
    record) RECORD="$value" ;;
    json_log) JSON_LOG="$value" ;;
    check_only) require_boolean "$source:check_only" "$value"; CHECK_ONLY="$value" ;;
    *) echo "ERROR: unknown reservation config key '$key' at $source" >&2; exit 2 ;;
  esac
}

find_config_argument "$@"
[[ -z "$CONFIG_FILE" ]] || load_config_file "$CONFIG_FILE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)         need_value "$@"; shift 2 ;;
    --config=*)       shift ;;
    --machine-type)   need_value "$@"; MACHINE_TYPE="$2"; shift 2 ;;
    --machine-type=*) MACHINE_TYPE="${1#*=}"; shift ;;
    --region)         need_value "$@"; REGION="$2"; shift 2 ;;
    --region=*)       REGION="${1#*=}"; shift ;;
    --delay)          need_value "$@"; DELAY="$2"; shift 2 ;;
    --delay=*)        DELAY="${1#*=}"; shift ;;
    --max-delay)      need_value "$@"; MAX_DELAY="$2"; shift 2 ;;
    --max-delay=*)    MAX_DELAY="${1#*=}"; shift ;;
    --max-attempts)   need_value "$@"; MAX_ATTEMPTS="$2"; shift 2 ;;
    --max-attempts=*) MAX_ATTEMPTS="${1#*=}"; shift ;;
    --count)          need_value "$@"; TARGET="$2"; shift 2 ;;
    --count=*)        TARGET="${1#*=}"; shift ;;
    --project)        need_value "$@"; PROJECT="$2"; shift 2 ;;
    --project=*)      PROJECT="${1#*=}"; shift ;;
    --zones)          need_value "$@"; ZONES_CSV="$2"; shift 2 ;;
    --zones=*)        ZONES_CSV="${1#*=}"; shift ;;
    --specific)       SPECIFIC=true; shift ;;
    --specific=*)     require_boolean "--specific" "${1#*=}"; SPECIFIC="${1#*=}"; shift ;;
    --record)         need_value "$@"; RECORD="$2"; shift 2 ;;
    --record=*)       RECORD="${1#*=}"; shift ;;
    --json-log)       need_value "$@"; JSON_LOG="$2"; shift 2 ;;
    --json-log=*)     JSON_LOG="${1#*=}"; shift ;;
    --check-only)     CHECK_ONLY=true; shift ;;
    --check-only=*)   require_boolean "--check-only" "${1#*=}"; CHECK_ONLY="${1#*=}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; echo; usage >&2; exit 2 ;;
  esac
done

[[ -n "$MACHINE_TYPE" ]] || { echo "ERROR: --machine-type is required" >&2; exit 2; }
[[ -n "$REGION" ]]       || { echo "ERROR: --region is required" >&2; exit 2; }
[[ -n "$DELAY" ]]        || { echo "ERROR: --delay is required" >&2; exit 2; }
[[ -n "$TARGET" ]]       || { echo "ERROR: --count is required" >&2; exit 2; }
[[ "$MACHINE_TYPE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: invalid machine type '$MACHINE_TYPE'" >&2; exit 2; }
[[ "$REGION" =~ ^[a-z][a-z0-9-]*[0-9]$ ]]     || { echo "ERROR: invalid region '$REGION'" >&2; exit 2; }
[[ "$DELAY" =~ ^[0-9]+$ ]]                     || { echo "ERROR: --delay must be integer seconds, got '$DELAY'" >&2; exit 2; }
[[ "$MAX_DELAY" =~ ^[0-9]+$ ]]                 || { echo "ERROR: --max-delay must be an integer" >&2; exit 2; }
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]]              || { echo "ERROR: --max-attempts must be an integer" >&2; exit 2; }
[[ "$TARGET" =~ ^[0-9]+$ && "$TARGET" -gt 0 ]] || { echo "ERROR: --count must be a positive integer" >&2; exit 2; }
[[ "$MAX_DELAY" -ge "$DELAY" ]] || { echo "ERROR: --max-delay must be at least --delay" >&2; exit 2; }
command -v gcloud >/dev/null || { echo "ERROR: gcloud not found on PATH" >&2; exit 1; }
[[ -z "$PROJECT" ]] && PROJECT="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT" ]] || { echo "ERROR: no project (pass --project or set gcloud config)" >&2; exit 2; }

ZONES=()
if [[ -n "$ZONES_CSV" ]]; then
  IFS=',' read -r -a ZONES <<< "$ZONES_CSV"
  for zone in "${ZONES[@]}"; do
    [[ -n "$zone" && "$zone" == "$REGION-"* ]] || {
      echo "ERROR: zone '$zone' is not in region '$REGION'" >&2
      exit 2
    }
  done
else
  while IFS= read -r zone; do [[ -n "$zone" ]] && ZONES+=("$zone"); done < <(
    gcloud compute zones list --project "$PROJECT" \
      --filter="region:( $REGION ) AND status=UP" --format="value(name)" 2>/dev/null
  )
fi
[[ ${#ZONES[@]} -gt 0 ]] || { echo "ERROR: no UP zones found for region '$REGION' in project '$PROJECT'" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
PREFIX="capgrab-${MACHINE_TYPE//./-}"
[[ -n "$RECORD" ]] || RECORD="reservations-${STAMP}.txt"
[[ "$RECORD" == /* ]] || RECORD="$ROOT/$RECORD"
[[ -d "$(dirname "$RECORD")" ]] || { echo "ERROR: record directory does not exist: $(dirname "$RECORD")" >&2; exit 2; }
LOCK_FILE="$RECORD.lock"
[[ -n "$JSON_LOG" ]] || JSON_LOG="${RECORD%.txt}.jsonl"
[[ "$JSON_LOG" == /* ]] || JSON_LOG="$ROOT/$JSON_LOG"
[[ -d "$(dirname "$JSON_LOG")" ]] || { echo "ERROR: JSON log directory does not exist: $(dirname "$JSON_LOG")" >&2; exit 2; }

run_preflight() {
  local zone failed=0
  echo "Running read-only preflight checks"
  gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null || return 1
  for zone in "${ZONES[@]}"; do
    if gcloud compute machine-types describe "$MACHINE_TYPE" --zone "$zone" --project "$PROJECT" --format='value(name)' >/dev/null 2>&1; then
      echo "  OK $MACHINE_TYPE in $zone"
    else
      echo "  FAIL $MACHINE_TYPE in $zone" >&2
      failed=1
    fi
  done
  echo "IAM create permission, quota headroom, and live capacity require a real reservation request."
  [[ $failed -eq 0 ]]
}

if [[ "$CHECK_ONLY" == true ]]; then
  run_preflight
  exit $?
fi

printf '# project=%s\n# machine_type=%s\n# specific=%s\n' "$PROJECT" "$MACHINE_TYPE" "$SPECIFIC" > "$RECORD"
: > "$LOCK_FILE"
created=0
cleanup() {
  rm -f "$LOCK_FILE"
}
print_summary() {
  echo
  echo "Secured $created/$TARGET reservation(s). Names and zones: $RECORD"
  echo "Attempt log: $JSON_LOG"
  if [[ $created -gt 0 ]]; then
    echo "These hold capacity and incur cost until deleted. Release them with:"
    echo "  ./release_reservations.sh --file $RECORD --project $PROJECT"
    if [[ "$SPECIFIC" == true ]]; then
      echo "To consume one, create a matching VM in its zone with:"
      echo "  gcloud compute instances create VM_NAME --project $PROJECT --zone ZONE --machine-type $MACHINE_TYPE --reservation-affinity=specific --reservation RESERVATION_NAME"
    fi
  fi
}
interrupt() {
  echo
  echo "Interrupted. Reconcile the record with: gcloud compute reservations list --project $PROJECT"
  print_summary
  exit 130
}
trap cleanup EXIT
trap interrupt INT TERM

echo "Reserving capacity"
echo "  project       : $PROJECT"
echo "  machine type  : $MACHINE_TYPE"
echo "  region        : $REGION"
echo "  zones tried   : ${ZONES[*]}"
echo "  target        : $TARGET reservation(s), 1 VM each"
echo "  consumption   : $([[ "$SPECIFIC" == true ]] && echo specific || echo shared-pool)"
echo "  retry delay   : ${DELAY}s initial, ${MAX_DELAY}s maximum"
echo "  attempt log   : $JSON_LOG"
echo

attempt=0
blocked_in_row=0
failures=0
total_zones=${#ZONES[@]}
while (( created < TARGET )); do
  for zone in "${ZONES[@]}"; do
    (( created >= TARGET )) && break
    attempt=$((attempt + 1))
    suffix="-${zone}-${STAMP}-${attempt}"
    prefix_limit=$((63 - ${#suffix}))
    [[ $prefix_limit -gt 0 ]] || { echo "ERROR: generated reservation suffix is too long" >&2; exit 1; }
    name="${PREFIX:0:$prefix_limit}${suffix}"
    printf '[%s] attempt %-4d %-16s -> %-32s ... ' "$(date '+%Y-%m-%d %H:%M:%S')" "$attempt" "$zone" "$name"

    create_args=(gcloud compute reservations create "$name" --project "$PROJECT" --zone "$zone" --vm-count 1 --machine-type "$MACHINE_TYPE" --quiet)
    [[ "$SPECIFIC" == false ]] || create_args+=(--require-specific-reservation)
    if out=$("${create_args[@]}" 2>&1); then
      created=$((created + 1))
      blocked_in_row=0
      echo "$name $zone" >> "$RECORD"
      echo "RESERVED ($created/$TARGET)"
      write_attempt_log "$JSON_LOG" reservations "$attempt" "$zone" "$MACHINE_TYPE" success
      continue
    fi

    failures=$((failures + 1))
    if grep -qiE "does not have enough resources|ZONE_RESOURCE_POOL_EXHAUSTED|stockout" <<<"$out"; then
      echo "STOCKOUT"
      write_attempt_log "$JSON_LOG" reservations "$attempt" "$zone" "$MACHINE_TYPE" stockout
      blocked_in_row=0
    elif grep -qiE "quota|QUOTA_EXCEEDED|exceeded limit" <<<"$out"; then
      echo "QUOTA (needs an increase)"
      write_attempt_log "$JSON_LOG" reservations "$attempt" "$zone" "$MACHINE_TYPE" quota
      blocked_in_row=$((blocked_in_row + 1))
    elif grep -qiE "rate.?limit|RESOURCE_OPERATION_RATE_EXCEEDED|429" <<<"$out"; then
      echo "RATE LIMIT"
      write_attempt_log "$JSON_LOG" reservations "$attempt" "$zone" "$MACHINE_TYPE" rate_limit
      blocked_in_row=0
    else
      echo "ERROR:"
      echo "$out" | tail -3 | sed 's/^/      /'
      write_attempt_log "$JSON_LOG" reservations "$attempt" "$zone" "$MACHINE_TYPE" error
      blocked_in_row=$((blocked_in_row + 1))
    fi

    if [[ $blocked_in_row -ge $total_zones ]]; then
      echo
      echo "Every zone hit quota or a permanent error for a full cycle."
      print_summary
      exit 1
    fi
    if [[ "$MAX_ATTEMPTS" -gt 0 && "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
      echo
      echo "Reached max attempts ($MAX_ATTEMPTS) before securing all reservations."
      print_summary
      exit 1
    fi
    sleep_after_failure "$DELAY" "$MAX_DELAY" "$failures"
  done
done

echo
echo "Done: secured $TARGET reservation(s)"
print_summary
