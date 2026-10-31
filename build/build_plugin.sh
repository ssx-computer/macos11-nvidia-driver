#!/bin/bash
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
N=$HOME/nvmtl-build; S=$N/LIVE/plugin; L=$N/build.lock
cd $S || exit 2
[ -z "$(git status --porcelain)" ] || { echo "STOP: LIVE/plugin has uncommitted edits — commit them first:"; git status --short | head; exit 3; }
C=$(git rev-parse --short HEAD); O=$N/LIVE/out/plugin-$C${RELEASE:+-release}; mkdir -p $O
RDEF=""; [ -n "${RELEASE:-}" ] && RDEF="-DNVMTL_RELEASE=1"
MINOS=${MINOS:-15.0}   # deployment target; set MINOS=11.0 in the CI for macOS 11 (Big Sur)
# Where the plugin looks for the NVK/translator payload. macOS 14+ keeps it in /Library/GPUBundles;
# on macOS 11 the driver's own kext carries it under /Library/NullMoth, so the CI overrides this.
BUNDLEDEF=(); [ -z "${NVMTL_BUNDLE_DIR:-}" ] || BUNDLEDEF=(-DNVMTL_BUNDLE_DIR="\"$NVMTL_BUNDLE_DIR\"")
# macOS 13+ SDK targetting an older minos emits unguarded-availability for Metal 3 APIs. The
# NullMoth driver forwards unimplemented selectors at runtime (NVMTLForward.m) and WindowServer on
# macOS 11 never calls Metal 3 methods, so we do NOT promote those to errors for a macOS 11 target.
if [ "$MINOS" \>= 15.0 ]; then MINOSFLAG=(-mmacosx-version-min=$MINOS -Werror=unguarded-availability-new)
else MINOSFLAG=(-mmacosx-version-min=$MINOS -Wunguarded-availability-new); fi
until mkdir $L 2>/dev/null; do sleep 5; done; echo "build_plugin $C $$" > $L/owner; trap 'rm -rf "$L"' EXIT
xcrun clang -arch x86_64 -march=x86-64 -bundle -fobjc-arc -O1 $RDEF "${MINOSFLAG[@]}" ${BUNDLEDEF[@]+"${BUNDLEDEF[@]}"} -Wno-protocol -Wno-incomplete-implementation \
  -I"$HOME/Vulkan-Headers/include" -o $O/NVMTLDriver NVMTLDevice.m \
  -framework Foundation -framework Metal -framework IOSurface 2>$O/NVMTLDriver.err \
  || { echo "STOP: compile failed"; grep -A2 ': error:' $O/NVMTLDriver.err | head -30; exit 5; }
codesign -f -s - $O/NVMTLDriver 2>/dev/null
miss=0
while IFS='|' read -r feat pat; do
  [ -z "$feat" ] && continue
  n=$(strings -a $O/NVMTLDriver | grep -c -- "$pat")
  case "$feat" in "fps file"|"passtime instrument") if [ -n "${RELEASE:-}" ]; then [ "$n" -eq 0 ] || { echo "  LEAKED diagnostic $feat  ($pat)"; miss=$((miss+1)); }; continue; fi;; esac
  [ "$n" -ge 1 ] || { echo "  MISSING $feat  ($pat)"; miss=$((miss+1)); }
done <<'M'
vendor compiler lane (NVIDIAShared)|NVIDIAShared
SASS dispatch on NVK (sasspipe)|nvmtl_nvk_dispatch_sass_v1
vendor variant (Apple MTLCompiler handshake)|vendor variant
bindless-all heap slots|bindless-all - textures reach shaders
dirty-only bindings|NVMTL_NO_DIRTYONLY
fullclear (Apple whole-attachment clear)|begin_render: fullclear
per-stage binding mask (gfx-bmask)|gmask
fps file|nvmtl-fps-
passtime instrument|nvmtl-passtime-request
library key memo (xlate)|library key memo: hit
res2-evict (Apple order: newest wins the card)|on the allocating thread
M
echo "plugin-$C  sha $(shasum -a256 $O/NVMTLDriver | cut -c1-8)  uuid $(otool -l $O/NVMTLDriver | awk '/uuid/{print $2; exit}')  warnings $(grep -c ': warning:' $O/NVMTLDriver.err)  markers-missing $miss"
[ $miss = 0 ] || { echo "STOP: a live feature is missing from this build — do NOT stage it"; exit 6; }
echo "$O/NVMTLDriver"
