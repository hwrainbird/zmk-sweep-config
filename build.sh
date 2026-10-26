#!/bin/sh
# build.sh: build the Sweep's firmware on this computer, the way GitHub does.
#
#   ./build.sh                both halves, into firmware/
#   ./build.sh left           one half: left or right
#   ./build.sh --flash        build, then copy each half onto the keyboard as
#   ./build.sh --flash left   soon as it's in its bootloader (left: Space + Q,
#                             right: Space + /), so there's no file to drag
#
# It runs ZMK's own build image (zmkfirmware/zmk-build-arm:stable) in Docker
# with the steps of ZMK's GitHub workflow (.github/workflows/build-user-config.yml
# in ZMK v0.3): a west workspace of its own, config/ as its manifest, and this
# repo as an extra Zephyr module. Same compiler, same result as GitHub.
#
# The workspace (ZMK, Zephyr and their modules, about 1.5 GB) is kept in the
# Docker volume zmk-sweep-workspace, so after the first build only what changed
# is rebuilt. Changing config/west.yml fetches again; `docker volume rm
# zmk-sweep-workspace` starts from scratch. The halves come from build.yaml.
#
# Needs Docker: Docker Desktop on macOS (started for you if it isn't running),
# or the docker service on Linux. Settings: ZMK_IMAGE, ZMK_VOLUME.
set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
OUT=$REPO/firmware
IMAGE=${ZMK_IMAGE:-zmkfirmware/zmk-build-arm:stable}
VOLUME=${ZMK_VOLUME:-zmk-sweep-workspace}

flash=false
half=""
for arg in "$@"; do
  case $arg in
    --flash) flash=true ;;
    left | right) half=$arg ;;
    -h | --help) sed -n '2,23s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown argument '$arg' (see --help)" >&2; exit 2 ;;
  esac
done

# "board shield" pairs from build.yaml's include list, skipping its comments
pairs=$(awk '/^[[:space:]]*#/ { next } /board:/ { board = $NF } /shield:/ { print board, $NF }' "$REPO/build.yaml" |
  grep -- "${half:+_$half}" || true)
[ -n "$pairs" ] || { echo "build.sh: no ${half:+$half }shield in build.yaml" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then
  if [ "$(uname -s)" = Darwin ]; then
    echo "Starting Docker Desktop..."
    open -ga Docker
    tries=0
    until docker info >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ $tries -lt 60 ] || { echo "build.sh: Docker didn't start" >&2; exit 1; }
      sleep 2
    done
  else
    echo "build.sh: Docker isn't running (try: sudo systemctl start docker)" >&2
    exit 1
  fi
fi

mkdir -p "$OUT"
# shellcheck disable=SC2086  # $pairs is meant to split into board shield ...
docker run --rm \
  -v "$VOLUME:/workspace" \
  -v "$REPO/config:/workspace/config:ro" \
  -v "$REPO:/repo:ro" \
  -v "$OUT:/out" \
  -e HOST_IDS="$(id -u):$(id -g)" \
  "$IMAGE" sh -euc '
    cd /workspace
    [ -d .west ] || west init -l config
    if ! cmp -s config/west.yml .west-yml-fetched; then
      west update --fetch-opt=--filter=tree:0
      cp config/west.yml .west-yml-fetched
    fi
    west zephyr-export >/dev/null  # registers Zephyr with CMake, which a new container forgets
    while [ $# -gt 0 ]; do
      board=$1 shield=$2
      shift 2
      echo "=== $shield ($board)"
      west build -p auto -s zmk/app -d "build/$shield" -b "$board" -- \
        -DSHIELD="$shield" -DZMK_CONFIG=/workspace/config -DZMK_EXTRA_MODULES=/repo
      cp "build/$shield/zephyr/zmk.uf2" "/out/$shield-$board-zmk.uf2"
      chown "$HOST_IDS" "/out/$shield-$board-zmk.uf2"  # not root-owned on Linux
    done
  ' sh $pairs

echo "Built into $OUT:"
ls -1 "$OUT"
$flash || exit 0

# A nice!nano in its bootloader shows up as a drive called NICENANO; copying
# the .uf2 onto it flashes it, and it restarts with the new firmware.
echo "$pairs" | while read -r board shield; do
  case $shield in
    *left*) keys="hold Space, tap Q" ;;
    *right*) keys="hold Space, tap /" ;;
    *) keys="double-tap its reset button" ;;
  esac
  echo "Flash $shield: put it in its bootloader ($keys), or plug it in and double-tap reset."
  drive=""
  while [ -z "$drive" ]; do
    for d in /Volumes/NICENANO "/run/media/${USER:-}/NICENANO" "/media/${USER:-}/NICENANO"; do
      [ -d "$d" ] && drive=$d && break
    done
    [ -n "$drive" ] || sleep 1
  done
  # The drive disappears as the half restarts, which cp can report as an error
  cp "$OUT/$shield-$board-zmk.uf2" "$drive/" 2>/dev/null || true
  echo "Flashed $shield."
  while [ -d "$drive" ]; do sleep 1; done  # gone before waiting for the next half
done
