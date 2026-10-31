#!/bin/bash
# build_plugin_release.sh <git-rev> <out-dir>: the release NVMTLDriver from plugin/ at <git-rev>, built on the build Mac
# (ssh host "mini") and copied back to <out-dir>. The package installs one plugin on macOS 15 and 26, so it is built
# for macOS 15: a plugin built against the 26 SDK without a deployment target carries minos 26.0 and dyld refuses it on
# Sequoia, which stopped every Sequoia install of 2.3.0 and 2.3.1. The build stops if the result is not minos 15.0 or
# if the compiler reports an API newer than macOS 15 used without an availability check.
set -euo pipefail
REV=${1:?git revision}; OUT=${2:?output directory}
HERE=$(cd "$(dirname "$0")/.." && pwd)
R=/Volumes/MiniData/build/plugin-release
TMP=$(mktemp -d)
MINOS=${MINOS:-15.0}   # deployment target; set MINOS=11.0 in the CI for macOS 11
# -Werror=unguarded-availability-new is meaningful only when targeting 15 or newer. On macOS 11 the
# plugin deliberately references newer API guarded at run time, and the compiler cannot prove it is
# never called, so the error has to stay off.
AVFLAG=(-Wunguarded-availability-new)
case "$MINOS" in 1[5-9]*|[2-9][0-9]*) AVFLAG=(-Werror=unguarded-availability-new);; esac
# Where the plugin looks for the NVK/translator payload. Default is /Library/GPUBundles (macOS 14+);
# macOS 11 has no such directory, so the CI passes the kext-owned location instead.
BUNDLEDEF=""
[ -z "${NVMTL_BUNDLE_DIR:-}" ] || BUNDLEDEF="-DNVMTL_BUNDLE_DIR=\\\"$NVMTL_BUNDLE_DIR\\\""
trap 'rm -rf "$TMP"' EXIT
git -C "$HERE" archive "$REV" plugin | tar x -C "$TMP"
ssh mini "rm -rf $R/src $R/out && mkdir -p $R/src $R/out"
rsync -a "$TMP/plugin/" "mini:$R/src/"
ssh mini "cd $R/src && xcrun clang -arch x86_64 -march=x86-64 -mmacosx-version-min=$MINOS -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 \
  $BUNDLEDEF \
  -Wno-protocol -Wno-incomplete-implementation ${AVFLAG[0]} \
  -I/Volumes/MiniData/build/gpu-src/mesa/include -o ../out/NVMTLDriver NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation 2>../out/build.err" \
  || { ssh mini "grep ' error:' $R/out/build.err | head -20"; exit 1; }
mkdir -p "$OUT"
scp -q "mini:$R/out/NVMTLDriver" "mini:$R/out/build.err" "$OUT/"
minos=$(vtool -show-build "$OUT/NVMTLDriver" | awk '/minos/{print $2; exit}')
[ "$minos" = "$MINOS" ] || { echo "STOP: minos $minos, not $MINOS"; exit 1; }
echo "NVMTLDriver $(git -C "$HERE" rev-parse --short "$REV") sha $(shasum -a 256 "$OUT/NVMTLDriver" | cut -c1-8) minos $minos warnings $(grep -c ': warning:' "$OUT/build.err" || true)"
