#!/usr/bin/env bash
# Fills the sha256 column of docker/versions.lock from the upstream tarballs.
#   ./scripts/update-lock.sh              # only rows still marked TODO
#   ./scripts/update-lock.sh --force      # re-pin every row
#   ./scripts/update-lock.sh 0.9.13       # only these versions
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK=docker/versions.lock

force=0
declare -a only=()
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) only+=("$arg") ;;
  esac
done

selected() {
  [ ${#only[@]} -eq 0 ] && return 0
  local v
  for v in "${only[@]}"; do [ "$v" = "$1" ] && return 0; done
  return 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/map"

pinned=0
skipped=0
while IFS=$'\t' read -r ver url sha _flags; do
  case "$ver" in ''|'#'*) continue ;; esac
  selected "$ver" || continue
  if [ "$force" -eq 0 ] && [ "${sha:0:4}" != "TODO" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "== $ver"
  echo "   $url"
  curl -fsSL --retry 3 -o "$tmp/$ver.tar.gz" "$url"
  new="$(sha256sum "$tmp/$ver.tar.gz" | cut -d' ' -f1)"
  echo "   sha256=$new"
  printf '%s\t%s\n' "$ver" "$new" >> "$tmp/map"
  pinned=$((pinned + 1))
done < "$LOCK"

if [ "$pinned" -eq 0 ]; then
  echo "nothing to pin (skipped $skipped already-pinned rows)"
  exit 0
fi

awk -F'\t' -v OFS='\t' '
  FNR == NR { m[$1] = $2; next }
  ($1 in m) { $3 = m[$1] }
  { print }
' "$tmp/map" "$LOCK" > "$tmp/lock.new"

mv "$tmp/lock.new" "$LOCK"
chmod 0644 "$LOCK"
echo "pinned $pinned release(s), skipped $skipped"
