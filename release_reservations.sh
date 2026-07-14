#!/usr/bin/env bash
# Delete every reservation recorded by grab_reservations.sh.
set -euo pipefail

usage() {
  echo "Usage: ./release_reservations.sh --file <reservations.txt> [--project <id>] [--yes]"
}

FILE=""
PROJECT=""
YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) [[ $# -ge 2 ]] || { echo "ERROR: --file requires a value" >&2; exit 2; }; FILE="$2"; shift 2 ;;
    --file=*) FILE="${1#*=}"; shift ;;
    --project) [[ $# -ge 2 ]] || { echo "ERROR: --project requires a value" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$FILE" ]] || { echo "ERROR: --file is required" >&2; exit 2; }
[[ -f "$FILE" ]] || { echo "ERROR: reservation file not found: $FILE" >&2; exit 2; }
[[ ! -e "$FILE.lock" ]] || { echo "ERROR: reservation run is still active: $FILE.lock exists" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "ERROR: gcloud not found on PATH" >&2; exit 1; }

mapfile_compat=()
record_project=""
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    "# project="*) record_project="${line#\# project=}"; continue ;;
    \#*|"") continue ;;
  esac
  read -r name zone extra <<< "$line"
  [[ -n "$name" && -n "$zone" && -z "${extra:-}" ]] || {
    echo "ERROR: invalid record in $FILE: '$name $zone ${extra:-}'" >&2
    exit 2
  }
  mapfile_compat+=("$name $zone")
done < "$FILE"
[[ -n "$PROJECT" ]] || PROJECT="$record_project"
[[ -n "$PROJECT" ]] || PROJECT="$(gcloud config get-value project 2>/dev/null)"
[[ -n "$PROJECT" ]] || { echo "ERROR: no project in the record, flags, or gcloud config" >&2; exit 2; }
[[ ${#mapfile_compat[@]} -gt 0 ]] || { echo "No reservations recorded in $FILE."; exit 0; }

echo "Reservations to delete from project '$PROJECT':"
printf '  %s\n' "${mapfile_compat[@]}"
if [[ "$YES" == false ]]; then
  read -r -p "Delete all listed reservations? [y/N] " answer || answer=""
  [[ "$answer" == y || "$answer" == Y ]] || { echo "Cancelled."; exit 1; }
fi

failed=0
for entry in "${mapfile_compat[@]}"; do
  read -r name zone <<< "$entry"
  if gcloud compute reservations delete "$name" --zone "$zone" --project "$PROJECT" --quiet; then
    echo "Deleted $name ($zone)"
  else
    echo "ERROR: failed to delete $name ($zone)" >&2
    failed=1
  fi
done
[[ $failed -eq 0 ]] || exit 1
echo "All recorded reservations were deleted."
