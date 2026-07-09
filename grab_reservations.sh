#!/usr/bin/env bash
# grab_reservations.sh: secure Compute Engine capacity by creating RESERVATIONS
# for a machine type in a region until a target number are held.
#
# Reservations are zonal, so this spreads attempts across the region's zones,
# creating single-VM reservations one at a time and retrying on STOCKOUT with a
# delay, until --count are secured. Unlike an on-demand instance, a reservation
# GUARANTEES the capacity is yours, but it HOLDS that capacity and incurs cost
# until you delete it (whether or not a VM is running against it).
#
# Prerequisites:
#   - gcloud authenticated with compute.reservations.create on the project
#
# Usage:
#   ./grab_reservations.sh --machine-type <type> --region <region> --delay <seconds> \
#       --count <n> [--project <id>] [--zones <csv>]
#
#     --machine-type   e.g. n2-highmem-128
#     --region         e.g. us-central1  (reservations spread across its zones)
#     --delay          integer seconds slept after a failed attempt
#     --count          how many single-VM reservations to secure
#     --project        optional; defaults to `gcloud config get-value project`
#     --zones          optional; restrict to these zones, e.g. "us-central1-a,us-central1-b"
#     -h, --help       show this help
#
# Example:
#   ./grab_reservations.sh --machine-type n2-highmem-128 --region us-central1 --delay 120 --count 4
set -uo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
Usage:
  ./grab_reservations.sh --machine-type <type> --region <region> --delay <seconds> \
      --count <n> [--project <id>] [--zones <csv>]

  --machine-type   e.g. n2-highmem-128
  --region         e.g. us-central1  (reservations spread across its zones)
  --delay          integer seconds slept after a failed attempt
  --count          how many single-VM reservations to secure
  --project        optional; defaults to `gcloud config get-value project`
  --zones          optional; restrict to these zones, e.g. "us-central1-a,us-central1-b"
  -h, --help       show this help

Example:
  ./grab_reservations.sh --machine-type n2-highmem-128 --region us-central1 --delay 120 --count 4
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
TARGET=""
PROJECT=""
ZONES_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --machine-type)   need_value "$@"; MACHINE_TYPE="$2"; shift 2 ;;
    --machine-type=*) MACHINE_TYPE="${1#*=}"; shift ;;
    --region)         need_value "$@"; REGION="$2"; shift 2 ;;
    --region=*)       REGION="${1#*=}"; shift ;;
    --delay)          need_value "$@"; DELAY="$2"; shift 2 ;;
    --delay=*)        DELAY="${1#*=}"; shift ;;
    --count)          need_value "$@"; TARGET="$2"; shift 2 ;;
    --count=*)        TARGET="${1#*=}"; shift ;;
    --project)        need_value "$@"; PROJECT="$2"; shift 2 ;;
    --project=*)      PROJECT="${1#*=}"; shift ;;
    --zones)          need_value "$@"; ZONES_CSV="$2"; shift 2 ;;
    --zones=*)        ZONES_CSV="${1#*=}"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; echo; usage >&2; exit 2 ;;
  esac
done

[[ -z "$PROJECT" ]] && PROJECT="$(gcloud config get-value project 2>/dev/null)"

[[ -n "$MACHINE_TYPE" ]] || { echo "ERROR: --machine-type is required" >&2; exit 2; }
[[ -n "$REGION" ]]       || { echo "ERROR: --region is required" >&2; exit 2; }
[[ -n "$DELAY" ]]        || { echo "ERROR: --delay is required" >&2; exit 2; }
[[ -n "$TARGET" ]]       || { echo "ERROR: --count is required" >&2; exit 2; }
[[ "$DELAY" =~ ^[0-9]+$ ]]                     || { echo "ERROR: --delay must be integer seconds, got '$DELAY'" >&2; exit 2; }
[[ "$TARGET" =~ ^[0-9]+$ && "$TARGET" -gt 0 ]] || { echo "ERROR: --count must be a positive integer" >&2; exit 2; }
[[ -n "$PROJECT" ]]         || { echo "ERROR: no project (pass --project or set gcloud config)" >&2; exit 2; }
command -v gcloud >/dev/null || { echo "ERROR: gcloud not found on PATH" >&2; exit 1; }

# Determine the zones to spread across.
ZONES=()
if [[ -n "$ZONES_CSV" ]]; then
  IFS=',' read -r -a ZONES <<< "$ZONES_CSV"
else
  while IFS= read -r z; do [[ -n "$z" ]] && ZONES+=("$z"); done < <(
    gcloud compute zones list --project "$PROJECT" \
      --filter="region:( $REGION ) AND status=UP" --format="value(name)" 2>/dev/null
  )
fi
[[ ${#ZONES[@]} -gt 0 ]] || { echo "ERROR: no UP zones found for region '$REGION' in project '$PROJECT'" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
PREFIX="capgrab-${MACHINE_TYPE//./-}"
RECORD="reservations-${STAMP}.txt"
: > "$RECORD"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

created=0
print_summary() {
  echo
  echo "Secured $created/$TARGET reservation(s). Names + zones recorded in: $RECORD"
  if [[ $created -gt 0 ]]; then
    echo "These HOLD capacity and incur cost until deleted. To delete them all:"
    echo "  while read -r n z; do gcloud compute reservations delete \"\$n\" --zone \"\$z\" --project $PROJECT -q; done < $RECORD"
  fi
}
trap 'echo; echo "Interrupted."; print_summary; exit 130' INT TERM

echo "Reserving capacity"
echo "  project       : $PROJECT"
echo "  machine type  : $MACHINE_TYPE"
echo "  region        : $REGION"
echo "  zones tried   : ${ZONES[*]}"
echo "  target        : $TARGET reservation(s), 1 VM each"
echo "  delay         : ${DELAY}s after a failed attempt"
echo

attempt=0
blocked_in_row=0
total_zones=${#ZONES[@]}
while (( created < TARGET )); do
  for zone in "${ZONES[@]}"; do
    (( created >= TARGET )) && break
    attempt=$((attempt + 1))
    name="${PREFIX}-${zone}-${STAMP}-${attempt}"
    printf '[%s] attempt %-4d %-16s -> %-32s ... ' "$(ts)" "$attempt" "$zone" "$name"

    if out=$(gcloud compute reservations create "$name" \
               --project "$PROJECT" --zone "$zone" \
               --vm-count 1 --machine-type "$MACHINE_TYPE" 2>&1); then
      created=$((created + 1))
      blocked_in_row=0
      echo "$name $zone" >> "$RECORD"
      echo "RESERVED ($created/$TARGET)"
      continue   # no delay after a success, keep accumulating
    fi

    if grep -qiE "does not have enough resources|ZONE_RESOURCE_POOL_EXHAUSTED|stockout" <<<"$out"; then
      echo "STOCKOUT"
      blocked_in_row=0
    elif grep -qiE "quota|QUOTA_EXCEEDED|exceeded limit" <<<"$out"; then
      echo "QUOTA (needs an increase)"
      blocked_in_row=$((blocked_in_row + 1))
    else
      echo "ERROR:"
      echo "$out" | tail -3 | sed 's/^/      /'
      blocked_in_row=$((blocked_in_row + 1))
    fi

    if [[ $blocked_in_row -ge $total_zones ]]; then
      echo
      echo "Every zone hit quota or errored for a full cycle. This looks like a"
      echo "configuration, permission, or quota problem, not a capacity one."
      print_summary
      exit 1
    fi
    sleep "$DELAY"
  done
done

echo
echo "Done: secured $TARGET reservation(s)"
print_summary
