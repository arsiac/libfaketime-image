#!/usr/bin/env bash
# Two kinds of check, kept apart on purpose.
#
#   hard      the artifact we built is the artifact we claim: the library
#             extracts and resolves every dependency on every target it is
#             supposed to run on. A failure here is our bug and fails the run.
#
#   advisory  how the release behaves at runtime. Upstream bugs are a property
#             of the release, not a defect of this repository, so they are
#             reported in the summary and do not fail the run. Set STRICT=1 to
#             make them fatal locally.
#
# Targets below the artifact's own ABI floor are skipped, not failed: an
# artifact built against glibc 2.41 cannot load on 2.31, by design.
set -uo pipefail

cd "$(dirname "$0")"

ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE="${1:?usage: test.sh <image>}"
# Matches INSTALL_PREFIX/lib/faketime in the Dockerfile.
LIB_DIR="${LIB_DIR:-/usr/local/lib/faketime}"
# Each entry is image or image=glibc_floor.
TARGETS="${TARGETS:-debian:11-slim=2.31 debian:12-slim=2.36 debian:13-slim=2.41}"
# ABI floor of the artifact under test. Results are only meaningful on targets
# at or above it.
GLIBC_FLOOR="${GLIBC_FLOOR:-}"
STRICT="${STRICT:-0}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"
OFFSET_DAYS=1
OFFSET=$((OFFSET_DAYS * 86400))

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

hard=0
adv=0
rows=()

fail_hard() { echo "HARD  $1" >&2; hard=$((hard + 1)); }
fail_adv()  { echo "ADV   $1" >&2; adv=$((adv + 1)); }
lower_than() { [ "$1" != "$2" ] && [ "$1" = "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" ]; }

echo "== extract $IMAGE ($LIB_DIR, ABI floor ${GLIBC_FLOOR:-unknown})"
if ! cid="$("$ENGINE" create "$IMAGE" 2>/dev/null)"; then
  echo "FATAL cannot create container from $IMAGE" >&2
  exit 1
fi
if ! "$ENGINE" cp "$cid:$LIB_DIR/libfaketime.so.1" "$tmp/libfaketime.so.1" 2>/dev/null; then
  "$ENGINE" rm -f "$cid" >/dev/null
  echo "FATAL $LIB_DIR/libfaketime.so.1 missing from $IMAGE" >&2
  exit 1
fi
"$ENGINE" rm -f "$cid" >/dev/null
ls -l "$tmp/libfaketime.so.1"

cat > "$tmp/probe.sh" <<'EOS'
: "${LIB_DIR:=/usr/local/lib/faketime}"
LIB="$LIB_DIR/libfaketime.so.1"
FAKE="+${OFFSET_DAYS}d"
# The preload is applied per command, never exported: upstream enables
# -DFAKE_SLEEP by default, and a globally exported preload would fast-forward
# the sleep below, making the advance measurement meaningless.
fdate() { LD_PRELOAD="$LIB" FAKETIME="$FAKE" DONT_FAKE_MONOTONIC=1 date "$@"; }
fstat() { LD_PRELOAD="$LIB" FAKETIME="$FAKE" DONT_FAKE_MONOTONIC=1 stat -c %Y "$1"; }
f=$(mktemp)
: > "$f"
echo "fake=$(fdate +%s)"
a=$(fdate +%s%N)
sleep 1
b=$(fdate +%s%N)
echo "elapsed_ms=$(( (b - a) / 1000000 ))"
echo "fake_mtime=$(fstat "$f")"
echo "real=$(date +%s)"
echo "real_mtime=$(stat -c %Y "$f")"
EOS

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

for entry in $TARGETS; do
  target="${entry%%=*}"
  target_floor=""
  if [ "$target" != "$entry" ]; then target_floor="${entry#*=}"; fi

  if [ -n "$target_floor" ] && [ -n "$GLIBC_FLOOR" ] && lower_than "$target_floor" "$GLIBC_FLOOR"; then
    echo "== $target (glibc $target_floor) skipped: below the artifact's $GLIBC_FLOOR floor"
    continue
  fi

  echo "== $target"

  # Dependency resolution is ours to get right: a missing NEEDED entry means the
  # image is broken wherever it is copied to.
  if ! ldd_out="$("$ENGINE" run --rm \
        -e LIB_DIR="$LIB_DIR" \
        -v "$tmp/libfaketime.so.1:/tmp/libfaketime.so.1:ro" \
        "$target" sh -c 'mkdir -p "$LIB_DIR" 2>/dev/null || LIB_DIR=/tmp; cp -f /tmp/libfaketime.so.1 "$LIB_DIR/" 2>/dev/null || LIB_DIR=/tmp; ldd "$LIB_DIR/libfaketime.so.1"' 2>&1)"; then
    fail_hard "$target: ldd could not run"
    rows+=("$target|-|-|-|ldd failed")
    continue
  fi
  missing="$(printf '%s\n' "$ldd_out" | grep -c 'not found')"
  if [ "$missing" != "0" ]; then
    fail_hard "$target: $missing unresolved shared libraries"
    printf '%s\n' "$ldd_out" | grep 'not found' >&2
    rows+=("$target|-|-|-|unresolved libs")
    continue
  fi

  # Runtime behaviour is the release's business, not ours.
  out="$("$ENGINE" run --rm \
        -e OFFSET_DAYS="$OFFSET_DAYS" \
        -e LIB_DIR="$LIB_DIR" \
        -v "$tmp/libfaketime.so.1:/tmp/libfaketime.so.1:ro" \
        -v "$tmp/probe.sh:/probe.sh:ro" \
        "$target" sh -c 'mkdir -p "$LIB_DIR" 2>/dev/null || LIB_DIR=/tmp; cp -f /tmp/libfaketime.so.1 "$LIB_DIR/" 2>/dev/null || LIB_DIR=/tmp; exec timeout '"$PROBE_TIMEOUT"' sh /probe.sh' 2>&1)"
  rc=$?

  if [ "$rc" = "124" ]; then
    fail_adv "$target: still running after ${PROBE_TIMEOUT}s (hangs on startup)"
    rows+=("$target|-|-|-|hangs")
    continue
  fi
  if [ "$rc" != "0" ]; then
    fail_adv "$target: probe exited $rc"
    printf '%s\n' "$out" >&2
    rows+=("$target|-|-|-|probe rc=$rc")
    continue
  fi

  fake="$(field "$out" fake)"
  real="$(field "$out" real)"
  elapsed="$(field "$out" elapsed_ms)"
  fake_mtime="$(field "$out" fake_mtime)"
  real_mtime="$(field "$out" real_mtime)"

  shift_epoch=$((fake - real))
  shift_mtime=$((fake_mtime - real_mtime))

  note=""
  if (( shift_epoch < OFFSET - 400 || shift_epoch > OFFSET + 400 )); then
    fail_adv "$target: clock offset ${shift_epoch}s, expected ~${OFFSET}s"
    note="offset!"
  fi
  if (( elapsed < 900 || elapsed > 3000 )); then
    fail_adv "$target: clock advanced ${elapsed}ms in 1s"
    note="${note}advance!"
  fi

  if (( shift_mtime >= OFFSET - 400 )); then stat_state=yes; else stat_state=no; fi
  rows+=("$target|${shift_epoch}|${elapsed}|$stat_state|$note")
done

echo
printf '%-22s %10s %10s %10s %s\n' target offset_s advance_ms stat_faked note
for row in "${rows[@]}"; do
  IFS='|' read -r t a b c d <<< "$row"
  printf '%-22s %10s %10s %10s %s\n' "$t" "$a" "$b" "$c" "$d"
done

echo
echo "hard failures: $hard, advisory: $adv"
if [ "$hard" -gt 0 ]; then
  echo "FAILED: the built artifact is not sound" >&2
  exit 1
fi
if [ "$STRICT" = "1" ] && [ "$adv" -gt 0 ]; then
  echo "FAILED: STRICT=1 and the release misbehaved" >&2
  exit 1
fi
echo "OK"
