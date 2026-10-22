#!/usr/bin/env bash
# Reports what each image actually supports, one row per runtime environment.
#
# The library is byte-identical in every carrier, but the glibc it runs on is
# not, so an image is exactly one environment to measure.
#
#   ./scripts/capabilities.sh <image> [image...]
#   ./scripts/capabilities.sh --local
#
# TARGETS mounts the artifact into other base systems instead of running inside
# the image:
#
#   TARGETS="debian:11-slim debian:12-slim" ./scripts/capabilities.sh <image>
#
# FORMAT=markdown emits a table meant to be pasted into release notes.
#
# Every measurement is taken independently and reported independently: a cell
# says "hangs" when that particular call deadlocked, and the remaining cells are
# still measured. A release that deadlocks on one path is exactly the case worth
# documenting, so nothing is skipped because of it.
#
# Columns:
#   arch      uname -m as reported inside the environment
#   glibc     libc version, from getconf GNU_LIBC_VERSION
#   offset    seconds the clock shifted under FAKETIME=+1d (86400 = works)
#   freeze    whether a bare timestamp sets the clock (yes/no)
#   anchor    whether @<timestamp> sets the clock (yes/no)
#   sleep_ms  real milliseconds a "sleep 1" took under FAKETIME=+1d
#             (<1000 = sleep() itself is accelerated)
#   stat      whether reading a file mtime returns a faked timestamp
#   touch     seconds a newly created file mtime was shifted by
#
# Not reported: whether an anchored clock keeps advancing. That needs two
# samples inside one process, and the only interpreter in these images (bash)
# reads the clock without going through LD_PRELOAD: its EPOCHSECONDS ignores
# faking while a child "date" honours it. Every "date" is a new process and
# re-anchors, so two samples would always agree.
set -uo pipefail

cd "$(dirname "$0")/.."

ENGINE="${CONTAINER_ENGINE:-podman}"
PREFIX="${PREFIX:-arsiachou/libfaketime}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/faketime}"
TARGETS="${TARGETS:-}"
FORMAT="${FORMAT:-table}"

images=()
for arg in "$@"; do
  case "$arg" in
    --local)
      while IFS= read -r ref; do images+=("$ref"); done < <(
        "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' | grep -E "^(localhost/)?${PREFIX}:" | sort -V
      )
      ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) images+=("$arg") ;;
  esac
done

if [ ${#images[@]} -eq 0 ]; then
  echo "usage: $0 <image> [image...] | --local" >&2
  exit 1
fi

PROBE=$(cat <<'EOS'
LIB="${LIB_DIR}/libfaketime.so.1"
[ -f "$LIB" ] || { echo "error=no-library"; exit 1; }
echo "arch=$(uname -m 2>/dev/null || echo unknown)"
echo "glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | sed 's/^glibc //' || echo unknown)"

# Each helper reports "hangs" instead of a value, so one deadlocked call cannot
# be mistaken for a measurement and cannot stop the remaining probes.
ft() {  # ft <seconds> <args...>
  cap="$1"; shift
  out=$(timeout "$cap" env LD_PRELOAD="$LIB" DONT_FAKE_MONOTONIC=1 "$@" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 124 ]; then echo hangs; return; fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then echo hangs; return; fi
  echo "$out"
}

now=$(date +%s)

o=$(FAKETIME='+1d' ft 3 date +%s)
if [ "$o" = hangs ]; then echo "offset=hangs"; else echo "offset=$((o - now))"; fi

for probe in freeze anchor; do
  if [ "$probe" = freeze ]; then val='2020-01-01 00:00:00'; else val='@2020-01-01 00:00:00'; fi
  v=$(FAKETIME="$val" ft 3 date +%s)
  if [ "$v" = hangs ]; then echo "$probe=hangs"; continue; fi
  if [ $((v - 1577836800)) -ge -5 ] && [ $((v - 1577836800)) -le 5 ]; then echo "$probe=yes"; else echo "$probe=no"; fi
done

t0=$(date +%s%N)
timeout 5 env LD_PRELOAD="$LIB" FAKETIME='+1d' DONT_FAKE_MONOTONIC=1 sleep 1 2>/dev/null
rc=$?
t1=$(date +%s%N)
if [ "$rc" -eq 124 ]; then echo "sleep_ms=hangs"; else echo "sleep_ms=$(( (t1 - t0) / 1000000 ))"; fi

f=$(mktemp); : > "$f"
fm=$(FAKETIME='+1d' ft 3 stat -c %Y "$f")
rms=$(stat -c %Y "$f" 2>/dev/null || echo 0)
if [ "$fm" = hangs ]; then echo "stat=hangs"; else
  if [ $((fm - rms)) -gt 3600 ]; then echo "stat=yes"; else echo "stat=no"; fi
fi

# touch prints nothing on success, so it is judged by exit status rather than
# by output, unlike the helpers above.
t=$(mktemp); rm -f "$t"
timeout 3 env LD_PRELOAD="$LIB" FAKETIME='+1d' DONT_FAKE_MONOTONIC=1 touch "$t" 2>/dev/null
trc=$?
tm=$(stat -c %Y "$t" 2>/dev/null || echo "")
if [ "$trc" -eq 124 ] || [ -z "$tm" ]; then echo "touch=hangs"; else echo "touch=$((tm - now))"; fi
EOS
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_probe() {  # $1 = image holding the library, $2 = target (empty = inside image)
  if [ -z "$2" ]; then
    timeout 180 "$ENGINE" run -i --rm --entrypoint sh -e LIB_DIR="$LIB_DIR" "$1" -s <<<"$PROBE" 2>/dev/null
  else
    timeout 180 "$ENGINE" run -i --rm -e LIB_DIR="$LIB_DIR" -v "$tmp/libfaketime.so.1:/tmp/libfaketime.so.1:ro" "$2" sh -c 'mkdir -p "$LIB_DIR" 2>/dev/null || LIB_DIR=/tmp; cp -f /tmp/libfaketime.so.1 "$LIB_DIR/" 2>/dev/null || LIB_DIR=/tmp; export LIB_DIR; exec sh -s' 2>/dev/null <<<"$PROBE"
  fi
}

COLS='offset freeze anchor sleep_ms stat touch'

if [ "$FORMAT" = "markdown" ]; then
  if [ -n "$TARGETS" ]; then
    echo '| image | arch | glibc | target | offset | freeze | anchor | sleep_ms | stat | touch |'
    echo '|---|---|---|---|---|---|---|---|---|---|'
  else
    echo '| image | arch | glibc | offset | freeze | anchor | sleep_ms | stat | touch |'
    echo '|---|---|---|---|---|---|---|---|---|'
  fi
else
  if [ -n "$TARGETS" ]; then
    printf '%-40s %-9s %-8s %-22s %8s %7s %7s %9s %6s %10s\n' image arch glibc target offset freeze anchor sleep_ms stat touch
  else
    printf '%-40s %-9s %-8s %8s %7s %7s %9s %6s %10s\n' image arch glibc offset freeze anchor sleep_ms stat touch
  fi
fi

for img in "${images[@]}"; do
  short="${img##*:}"
  if [ -n "$TARGETS" ]; then
    if ! cid="$("$ENGINE" create "$img" 2>/dev/null)"; then
      echo "cannot create container from $img" >&2
      continue
    fi
    if ! "$ENGINE" cp "$cid:$LIB_DIR/libfaketime.so.1" "$tmp/libfaketime.so.1" 2>/dev/null; then
      "$ENGINE" rm -f "$cid" >/dev/null
      echo "$short: no library at $LIB_DIR" >&2
      continue
    fi
    "$ENGINE" rm -f "$cid" >/dev/null
  fi

  list="${targets:-self}"
  for t in $list; do
    case "$t" in
      self) target="" ;;
      *=*)  target="${t%%=*}" ;;
      *)    target="$t" ;;
    esac
    out=$(run_probe "$img" "$target") || true
    get() {
      v="$(printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1)"
      [ -n "$v" ] || v=-
      echo "$v"
    }
    arch="$(get arch)"
    libc="$(get glibc)"
    cells="$(get offset) | $(get freeze) | $(get anchor) | $(get sleep_ms) | $(get stat) | $(get touch)"
    if [ "$FORMAT" = "markdown" ]; then
      if [ -n "$TARGETS" ]; then
        echo "| $short | $arch | $libc | $target | $cells |"
      else
        echo "| $short | $arch | $libc | $cells |"
      fi
    else
      if [ -n "$TARGETS" ]; then
        printf '%-40s %-9s %-8s %-22s %8s %7s %7s %9s %6s %10s\n' "$short" "$arch" "$libc" "$target" "$(get offset)" "$(get freeze)" "$(get anchor)" "$(get sleep_ms)" "$(get stat)" "$(get touch)"
      else
        printf '%-40s %-9s %-8s %8s %7s %7s %9s %6s %10s\n' "$short" "$arch" "$libc" "$(get offset)" "$(get freeze)" "$(get anchor)" "$(get sleep_ms)" "$(get stat)" "$(get touch)"
      fi
    fi
  done
done
