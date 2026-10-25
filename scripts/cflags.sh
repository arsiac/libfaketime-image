#!/usr/bin/env bash
# Prints the extra flags for one release on one baseline.
#   ./scripts/cflags.sh <version> <glibc>
#   ./scripts/cflags.sh --check
#
# Flags live in docker/cflags/<version>/<glibc>.flags; a missing file means the
# release needs none there, so the directory stays sparse. Lines may carry #
# comments.
set -euo pipefail

cd "$(dirname "$0")/.."

DIR=docker/cflags

check() {
  [ -d "$DIR" ] || return 0
  local dir version file glibc
  for dir in "$DIR"/*/; do
    [ -d "$dir" ] || continue
    version="$(basename "$dir")"
    awk -F'\t' -v v="$version" '!/^#/ && $1 == v { found = 1 } END { exit !found }' docker/versions.lock || {
      echo "docker/cflags/$version is not in docker/versions.lock" >&2
      exit 1
    }
    for file in "$dir"*; do
      [ -f "$file" ] || continue
      case "$file" in
        *.flags) ;;
        *) echo "$file is not a .flags file" >&2; exit 1 ;;
      esac
      glibc="$(basename "$file" .flags)"
      awk -F'\t' -v g="$glibc" '!/^#/ && $2 == g { found = 1 } END { exit !found }' docker/build-base.lock || {
        echo "$file names no baseline in docker/build-base.lock" >&2
        exit 1
      }
    done
  done
}

if [ "${1:-}" = "--check" ]; then
  check
  exit 0
fi

if [ "$#" -ne 2 ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

file="$DIR/$1/$2.flags"
[ -f "$file" ] || exit 0
awk '{ sub(/#.*/, ""); if ($0 ~ /[^[:space:]]/) printf "%s ", $0 }' "$file" | sed -e 's/[[:space:]]*$//'
