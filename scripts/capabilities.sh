#!/usr/bin/env bash
# Reports what each image actually supports, one row per tag and architecture.
#
#   ./scripts/capabilities.sh <image> [image...]
#   ./scripts/capabilities.sh --local
#   ./scripts/capabilities.sh --render rows.json [rows.json...]
#
# TARGETS mounts the artifact into other base systems instead of running inside
# the image:
#
#   TARGETS="debian:11-slim debian:12-slim" ./scripts/capabilities.sh <image>
#
# JSON_OUT writes the same rows as JSON; --gate exits non-zero when any row has
# a deadlocked or failed check. --notes adds the verdict legend and the scope
# statement. FORMAT selects markdown (default) or table.
#
# Verdict per row: ok, degraded (a check reports no), hang, error.
set -uo pipefail

cd "$(dirname "$0")/.."

ENGINE="${CONTAINER_ENGINE:-podman}"
PREFIX="${PREFIX:-arsiachou/libfaketime}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/faketime}"
TARGETS="${TARGETS:-}"
FORMAT="${FORMAT:-markdown}"
GLIBC_FLOOR="${GLIBC_FLOOR:-}"
JSON_OUT="${JSON_OUT:-}"
PROBE="${PROBE:-}"
GATE=0
RENDER=0
NOTES=0

images=()
render_inputs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --local)
      while IFS= read -r ref; do images+=("$ref"); done < <(
        "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' | grep -E "^(localhost/)?${PREFIX}:" | sort -V
      )
      shift
      ;;
    --gate) GATE=1; shift ;;
    --notes) NOTES=1; shift ;;
    --render)
      RENDER=1; shift
      while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do render_inputs+=("$1"); shift; done
      ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) images+=("$1"); shift ;;
  esac
done

# Rules live here so the verdict and the report cannot disagree.
declare -A KIND EXPECT
order=(time gtod gtod_tz clock_rt timespec_get clock_mono mono_default
       offset_neg freeze freeze_epoch anchor anchor_epoch rate tz
       stat stat_shift statx sleep_ms
       mt_thread cli)

KIND[time]=offset;            EXPECT[time]=86400
KIND[gtod]=offset;            EXPECT[gtod]=86400
KIND[clock_rt]=offset;        EXPECT[clock_rt]=86400
KIND[timespec_get]=offset;    EXPECT[timespec_get]=86400
KIND[offset_neg]=offset;      EXPECT[offset_neg]=-86400
KIND[clock_mono]=near;        EXPECT[clock_mono]=1000
KIND[mono_default]=near;      EXPECT[mono_default]=1000
KIND[sleep_ms]=near;          EXPECT[sleep_ms]=1000
KIND[rate]=near;              EXPECT[rate]=2000
KIND[freeze]=bool
KIND[anchor]=bool
KIND[tz]=bool
KIND[stat]=bool
KIND[statx]=bool
KIND[gtod_tz]=bool
KIND[mt_thread]=bool
KIND[cli]=optional
KIND[freeze_epoch]=info
KIND[anchor_epoch]=info
KIND[stat_shift]=info

judge() {  # $1 key, $2 value -> ok|bad|skip|hang|error
  local key="$1" val="$2" kind="${KIND[$1]:-info}" exp="${EXPECT[$1]:-0}" tol=5
  case "$val" in
    hangs) echo hang; return ;;
    error*) echo error; return ;;
    n/a) echo skip; return ;;
    "") echo error; return ;;
  esac
  case "$kind" in
    offset)
      [ $((val - exp)) -ge -$tol ] && [ $((val - exp)) -le $tol ] && echo ok || echo bad ;;
    near)
      if [ "$key" = rate ]; then tol=600; else tol=400; fi
      [ $((val - exp)) -ge -$tol ] && [ $((val - exp)) -le $tol ] && echo ok || echo bad ;;
    bool) [ "$val" = yes ] && echo ok || echo bad ;;
    optional)
      if [ "$val" = yes ]; then echo ok
      elif [ $((val - 86400)) -ge -5 ] && [ $((val - 86400)) -le 5 ]; then echo ok
      else echo bad; fi ;;
    *) echo ok ;;
  esac
}

build_probe() {
  local out="$1" row base glibc archived make_mode
  row="$(awk -F'\t' '!/^#/ && NF { print $0 }' docker/build-base.lock | sort -t$'\t' -k2,2V | head -1)"
  base="$(printf '%s' "$row" | cut -f1)"
  glibc="$(printf '%s' "$row" | cut -f2)"
  archived="$(printf '%s' "$row" | cut -f3)"
  make_mode="$(printf '%s' "$row" | cut -f4)"
  "$ENGINE" build --target toolchain \
    --build-arg BASE_TAG="$base" --build-arg GLIBC="$glibc" \
    --build-arg APT_ARCHIVE="$archived" --build-arg TOOLCHAIN_MAKE="$make_mode" \
    -t "lf-probe-toolchain:$glibc" . >&2 || return 1
  # The probe runs inside every carrier, so it is built against the oldest
  # baseline. It must stay dynamically linked: a static binary ignores
  # LD_PRELOAD and would measure nothing.
  "$ENGINE" run --rm -v "$PWD/test:/src:ro" -v "$(dirname "$out"):/out" \
    "lf-probe-toolchain:$glibc" cc -O2 -pthread -o "/out/$(basename "$out")" /src/probe.c || return 1
}

symver_of() {
  command -v readelf > /dev/null || { echo n/a; return; }
  # Only the needs section bounds the runtime ABI; the library also tags the
  # symbols it interposes with newer glibc versions it does not require.
  v="$(LC_ALL=C readelf --version-info "$1" 2>/dev/null | awk '
    /^Version needs section/ { n = 1; next }
    /^Version definition section|^Version symbols section/ { n = 0 }
    n && match($0, /GLIBC_[0-9.]+/) { print substr($0, RSTART + 6, RLENGTH - 6) }
  ' | sort -uV | tail -1)"
  echo "${v:-n/a}"
}

libs_of() {  # $1 image, $2 target (empty = inside the image), $3 .so path
  local img="$1" target="$2" so="$3" out missing
  if [ -n "$target" ]; then
    out="$("$ENGINE" run --rm -v "$so:/tmp/libfaketime.so.1:ro" "$target" \
      sh -c 'ldd /tmp/libfaketime.so.1 2>&1' 2>&1)"
  else
    out="$("$ENGINE" run --rm -v "$so:/tmp/libfaketime.so.1:ro" --entrypoint sh "$img" \
      -c 'ldd /tmp/libfaketime.so.1 2>&1' 2>&1)"
  fi
  missing="$(printf '%s\n' "$out" | grep -c 'not found')"
  printf '%s|%s\n' "$missing" "$(printf '%s' "$out" | tr '\n' ' ')"
}

PROBE_SCRIPT=$(cat <<'EOS'
D="${LIB_DIR:-/usr/local/lib/faketime}"
if [ -d /tmp/so ]; then
  mkdir -p "$D" 2>/dev/null || D=/tmp
  cp -f /tmp/so/libfaketime.so.1 /tmp/so/libfaketimeMT.so.1 "$D/" 2>/dev/null || true
fi
echo "arch=$(uname -m 2>/dev/null || echo unknown)"
echo "glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d' ' -f2)"
# A library that deadlocks at startup would otherwise cost one timeout per check;
# a missing symbol reports itself on stderr instead.
if ! timeout 8 env LD_PRELOAD="$D/$PROBE_LIB" /probe --check time > /dev/null 2> /tmp/probe.err; then
  if grep -qi 'not found\|GLIBC_' /tmp/probe.err; then
    echo "probe=error"
    echo "probe_detail=$(tr '\n' ' ' < /tmp/probe.err | cut -c1-240)"
  else
    echo "probe=hangs"
  fi
  exit 0
fi
LD_PRELOAD="$D/$PROBE_LIB" /probe $PROBE_ARGS
EOS
)

run_probe() {  # $1 image, $2 target (empty = inside the image), $3 lib, $4 probe args
  local img="$1" target="$2" lib="$3" args="$4"
  if [ -n "$target" ]; then
    timeout "${PROBE_TIMEOUT:-120}" "$ENGINE" run -i --rm -e LIB_DIR="$LIB_DIR" -e DONT_FAKE_MONOTONIC=1 \
      -e PROBE_LIB="$lib" -e PROBE_ARGS="$args" \
      -v "$tmp/so:/tmp/so:ro" -v "$PROBE:/probe:ro" "$target" sh -c "$PROBE_SCRIPT" 2>/dev/null
  else
    timeout "${PROBE_TIMEOUT:-120}" "$ENGINE" run -i --rm -e LIB_DIR="$LIB_DIR" -e DONT_FAKE_MONOTONIC=1 \
      -e PROBE_LIB="$lib" -e PROBE_ARGS="$args" \
      -v "$PROBE:/probe:ro" --entrypoint sh "$img" -c "$PROBE_SCRIPT" 2>/dev/null
  fi
}

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

verdict_of() {  # $1 libs, $2 symver, $3... check states
  local libs="$1" sym="$2" v
  shift 2
  for v in "$@"; do [ "$v" = hang ] && { echo hang; return; }; done
  for v in "$@"; do [ "$v" = error ] && { echo error; return; }; done
  if [ "$libs" != 0 ]; then echo error; return; fi
  if [ -n "$GLIBC_FLOOR" ] && [ "$sym" != n/a ] &&
     [ "$(printf '%s\n%s\n' "$sym" "$GLIBC_FLOOR" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
    echo error; return
  fi
  for v in "$@"; do [ "$v" = bad ] && { echo degraded; return; }; done
  echo ok
}

rows_json="[]"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$RENDER" = 1 ]; then
  [ ${#render_inputs[@]} -gt 0 ] || { echo "--render needs at least one json file" >&2; exit 1; }
  rows_json="$(jq -s 'add' "${render_inputs[@]}")"
else
  command -v "$ENGINE" > /dev/null || { echo "container engine '$ENGINE' is not installed (set CONTAINER_ENGINE)" >&2; exit 1; }
  [ ${#images[@]} -gt 0 ] || { echo "usage: $0 <image> [image...] | --local | --render <json...>" >&2; exit 1; }

  if [ -z "$PROBE" ]; then
    PROBE="$tmp/probe"
    build_probe "$PROBE" || { echo "cannot build the probe" >&2; exit 1; }
  fi
  [ -x "$PROBE" ] || { echo "probe $PROBE is not executable" >&2; exit 1; }

  mkdir -p "$tmp/so"

  for img in "${images[@]}"; do
    tag="${img##*:}"
    if ! cid="$("$ENGINE" create "$img" 2>/dev/null)"; then
      echo "cannot create container from $img" >&2
      continue
    fi
    if ! "$ENGINE" cp "$cid:$LIB_DIR/libfaketime.so.1" "$tmp/so/libfaketime.so.1" 2>/dev/null; then
      "$ENGINE" rm -f "$cid" > /dev/null
      echo "$tag: no library at $LIB_DIR" >&2
      continue
    fi
    "$ENGINE" cp "$cid:$LIB_DIR/libfaketimeMT.so.1" "$tmp/so/libfaketimeMT.so.1" 2>/dev/null || true
    "$ENGINE" rm -f "$cid" > /dev/null

    sha="$(sha256sum "$tmp/so/libfaketime.so.1" | cut -c1-12)"
    sym="$(symver_of "$tmp/so/libfaketime.so.1")"

    for t in ${TARGETS:-self}; do
      if [ "$t" = self ]; then target=""; else target="$t"; fi

      libs_out="$(libs_of "$img" "$target" "$tmp/so/libfaketime.so.1")"
      libs="${libs_out%%|*}"
      libs_detail="${libs_out#*|}"

      base="$(run_probe "$img" "$target" libfaketime.so.1 "--skip mt_thread")"
      mt="$(run_probe "$img" "$target" libfaketimeMT.so.1 "--only mt_thread")"

      arch="$(field "$base" arch)"; [ -n "$arch" ] || arch=unknown
      glibc="$(field "$base" glibc)"; [ -n "$glibc" ] || glibc=unknown

      checks_json="[]"
      judges=()
      probe_state="$(field "$base" probe)"
      probe_hang=0
      probe_err=0
      [ "$probe_state" = hangs ] && probe_hang=1
      [ "$probe_state" = error ] && probe_err=1
      for key in "${order[@]}"; do
        if [ "$probe_hang" = 1 ]; then
          val=hangs
        elif [ "$probe_err" = 1 ]; then
          val=error
        else
          val="$(field "$base" "$key")"
          [ -n "$val" ] || val="$(field "$mt" "$key")"
          [ -n "$val" ] || continue
        fi
        j="$(judge "$key" "$val")"
        judges+=("$j")
        checks_json="$(jq -c --arg k "$key" --arg v "$val" --arg j "$j" \
          '. + [{key: $k, value: $v, state: $j}]' <<< "$checks_json")"
      done

      verdict="$(verdict_of "$libs" "$sym" "${judges[@]:-}")"
      row="$(jq -n \
        --arg tag "$tag" --arg arch "$arch" --arg glibc "$glibc" \
        --arg sha "$sha" --arg symver "$sym" --arg libs "$libs" \
        --arg verdict "$verdict" --arg detail "$libs_detail" --arg target "$target" \
        --arg diagnostic "$(field "$base" probe_detail)" \
        --argjson checks "$checks_json" \
        '{tag: $tag, arch: $arch, glibc: $glibc, sha: $sha, symver: $symver,
          libs: ($libs | tonumber), libs_detail: $detail, verdict: $verdict, target: $target,
          diagnostic: $diagnostic, checks: $checks}')"
      rows_json="$(jq -c --argjson r "$row" '. + [$r]' <<< "$rows_json")"
      printf '%s (%s): %s\n' "$tag" "${target:-self}" "$verdict" >&2
    done
  done
fi

if [ -n "$JSON_OUT" ]; then
  printf '%s\n' "$rows_json" > "$JSON_OUT"
fi

render() {
  local rows="$1" with_pushed n i
  with_pushed="$(jq -r '[.[] | has("pushed")] | any' <<< "$rows")"
  if [ "$FORMAT" = table ]; then
    if [ "$with_pushed" = true ]; then
      printf '%-46s %-8s %-6s %-8s %8s %8s %7s %7s %6s %6s %5s %-9s %-14s %s\n' tag arch glibc abi offset gtod freeze rate stat tz mt verdict note pushed
    else
      printf '%-46s %-8s %-6s %-8s %8s %8s %7s %7s %6s %6s %5s %-9s %s\n' tag arch glibc abi offset gtod freeze rate stat tz mt verdict note
    fi
  else
    if [ "$with_pushed" = true ]; then
      echo '| tag | arch | glibc | abi | offset | gtod | freeze | rate | stat | tz | mt | verdict | note | pushed |'
      echo '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
    else
      echo '| tag | arch | glibc | abi | offset | gtod | freeze | rate | stat | tz | mt | verdict | note |'
      echo '|---|---|---|---|---|---|---|---|---|---|---|---|---|'
    fi
  fi

  cell() { jq -r --arg k "$2" '[.checks[] | select(.key == $k)][0].value // "-"' <<< "$1"; }
  bad_keys() { jq -r '[.checks[] | select(.state == "bad") | .key] | join(",")' <<< "$1"; }
  expected_of() {
    case "${KIND[$1]:-info}" in
      offset) printf '%s +-5' "${EXPECT[$1]}" ;;
      near) if [ "$1" = rate ]; then printf '%s +-600' "${EXPECT[$1]}"; else printf '%s +-400' "${EXPECT[$1]}"; fi ;;
      bool) printf 'yes' ;;
      optional) printf '86400 +-5 or n/a' ;;
      *) printf -- '-' ;;
    esac
  }

  n="$(jq 'length' <<< "$rows")"
  for ((i = 0; i < n; i++)); do
    local row tag arch glibc sym libs verdict pushed offset gtod freeze rate stat ut abi mtv
    row="$(jq -c ".[$i]" <<< "$rows")"
    tag="$(jq -r '.tag' <<< "$row")"
    tgt="$(jq -r '.target // ""' <<< "$row")"
    [ -n "$tgt" ] && tag="$tag ($tgt)"
    arch="$(jq -r '.arch' <<< "$row")"
    glibc="$(jq -r '.glibc' <<< "$row")"
    sym="$(jq -r '.symver' <<< "$row")"
    libs="$(jq -r '.libs' <<< "$row")"
    verdict="$(jq -r '.verdict' <<< "$row")"
    pushed="$(jq -r '.pushed // "-"' <<< "$row")"
    offset="$(cell "$row" time)"
    gtod="$(cell "$row" gtod)"
    freeze="$(cell "$row" freeze)"
    rate="$(cell "$row" rate)"
    stat="$(cell "$row" stat)"
    ut="$(cell "$row" tz)"
    mtv="$(cell "$row" mt_thread)"
    note="$(bad_keys "$row")"
    [ -n "$note" ] || note="-"
    abi="$sym"
    [ "$libs" != 0 ] && abi="libs=$libs"
    if [ "$FORMAT" = table ]; then
      if [ "$with_pushed" = true ]; then
        printf '%-46s %-8s %-6s %-8s %8s %8s %7s %7s %6s %6s %5s %-9s %-14s %s\n' "$tag" "$arch" "$glibc" "$abi" "$offset" "$gtod" "$freeze" "$rate" "$stat" "$ut" "$mtv" "$verdict" "$note" "$pushed"
      else
        printf '%-46s %-8s %-6s %-8s %8s %8s %7s %7s %6s %6s %5s %-9s %s\n' "$tag" "$arch" "$glibc" "$abi" "$offset" "$gtod" "$freeze" "$rate" "$stat" "$ut" "$mtv" "$verdict" "$note"
      fi
    else
      if [ "$with_pushed" = true ]; then
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$tag" "$arch" "$glibc" "$abi" "$offset" "$gtod" "$freeze" "$rate" "$stat" "$ut" "$mtv" "$verdict" "$note" "$pushed"
      else
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' "$tag" "$arch" "$glibc" "$abi" "$offset" "$gtod" "$freeze" "$rate" "$stat" "$ut" "$mtv" "$verdict" "$note"
      fi
    fi
  done

  # Markdown only: one collapsible block per row, failing checks first.
  if [ "$FORMAT" != table ]; then
    for ((i = 0; i < n; i++)); do
      local drow dtag dtgt darch dverdict ddiag
      drow="$(jq -c ".[$i]" <<< "$rows")"
      dtag="$(jq -r '.tag' <<< "$drow")"
      dtgt="$(jq -r '.target // ""' <<< "$drow")"
      [ -n "$dtgt" ] && dtag="$dtag ($dtgt)"
      darch="$(jq -r '.arch' <<< "$drow")"
      dverdict="$(jq -r '.verdict' <<< "$drow")"
      ddiag="$(jq -r '.diagnostic // ""' <<< "$drow")"
      printf '\n<details><summary>%s (%s): %s</summary>\n\n' "$dtag" "$darch" "$dverdict"
      printf '| check | expected | actual | state |\n|---|---|---|---|\n'
      # A run where every check hit the same wall is one line, not twenty.
      if [ "$(jq -r '[.checks[].state] | unique | length' <<< "$drow")" = 1 ] &&
         [ "$(jq -r '.checks[0].state' <<< "$drow")" != ok ]; then
        printf '| all checks | - | %s | %s |\n' "$(jq -r '.checks[0].value' <<< "$drow")" "$(jq -r '.checks[0].state' <<< "$drow")"
      else
        while IFS=$'\t' read -r k v s; do
          printf '| %s | %s | %s | %s |\n' "$k" "$(expected_of "$k")" "$v" "$s"
        done < <(jq -r '[.checks[] | . + {rank: (if (.state == "hang" or .state == "error" or .state == "bad") then 0 elif .state == "skip" then 2 else 1 end)}] | sort_by(.rank, .key) | .[] | [.key, .value, .state] | @tsv' <<< "$drow")
      fi
      if [ -n "$ddiag" ]; then
        printf '\n```\n%s\n```\n' "$ddiag"
      fi
      printf '\n</details>\n'
    done
  fi

  if [ "$NOTES" = 1 ]; then
    cat <<'EOF'

### Verdict

- `ok` — every check behaved as expected.
- `degraded` — nothing hangs or fails to load, but a check reports `no`; the
  image is still published and the `note` column names the check.
- `hang` — a preloaded process deadlocked while starting; the image is not
  published.
- `error` — the library could not be loaded or an ABI floor was exceeded; the
  image is not published.

### Not covered

- 32-bit `time_t` targets, musl, and statically linked programs.
- `pthread_cond_timedwait` accuracy and timer calls applications use directly.
- Timestamps read through raw syscalls by the tested process itself.
EOF
  fi
}

render "$rows_json"

if [ "$GATE" = 1 ]; then
  bad="$(jq '[.[] | select(.verdict == "hang" or .verdict == "error")] | length' <<< "$rows_json")"
  if [ "$bad" != 0 ]; then
    echo >&2
    echo "$bad image(s) failed: hang or error" >&2
    exit 1
  fi
fi
