#!/bin/sh
# Builds eSpeak NG (GPL-3.0-or-later) from the third_party/espeak-ng submodule, and its data, for Apple systems:
#
#   dotnet (the default)  Speechwarp.Voice.Espeak/native/ios/espeak-ng.xcframework (iPhones; simulators on both
#                         kinds of Mac) and Speechwarp.Voice.Espeak/native/espeak-ng-data, where the NuGet
#                         package takes them from.
#   swift                 bindings/swift/Frameworks/espeak_ng.xcframework (also macOS) and the data in
#                         bindings/swift/Sources/SpeechwarpVoiceEspeak/espeak-ng-data, for the SpeechwarpVoiceEspeak
#                         target of Package.swift.
#   all                   both.
#
# Needs Xcode and the submodule, which is not fetched by default:
#   git submodule update --init --checkout third_party/espeak-ng
#
# The library alone, compiled directly, static: eSpeak's CMake install rules fail for iOS, and an app links it in
# whole. Changes from a default build (see config.h): no audio output, MBROLA, Sonic or speech player; Klatt kept;
# a 1,024-byte data path, because the default 160 bytes is shorter than an app's bundle path in the simulator, and
# eSpeak then fails to find its data; and leNNtoh from OSByteOrder (apple_endian.h), which the iOS SDK's <endian.h>
# lacks.
#
# The data is compiled from source as upstream's Makefile does it, by upstream's own espeak-ng command built for
# this Mac. Only the dictionaries named in ESPEAK_DICTIONARIES are compiled (default "en", about 1.2 MB with
# English's accents and every voice variant); each needs its lang/ files, which are those named after it
# ("en", "en-GB-scotland" and so on). For example: ESPEAK_DICTIONARIES="en de fr" build-espeak.sh
#
# Nothing it produces is committed (see ../.gitignore and the repository's .gitignore); CI builds it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
package=$(cd "$here/.." && pwd)
root=$(cd "$here/../../../.." && pwd)
src="$root/third_party/espeak-ng"
what=${1:-dotnet}
dictionaries=${ESPEAK_DICTIONARIES:-en}
ios_minimum=15.0
macos_minimum=10.15

case "$what" in
  dotnet|swift|all) ;;
  *) echo "usage: $0 [dotnet|swift|all]" >&2; exit 2 ;;
esac
if [ ! -f "$src/src/libespeak-ng/speech.c" ]; then
  echo "eSpeak NG's source is missing. Fetch it with:" >&2
  echo "  git submodule update --init --checkout third_party/espeak-ng" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The library's sources, as listed in upstream's Makefile.am, less the asynchronous mode, audio output, MBROLA,
# Sonic and the speech player.
library="common mnemonics error ieee80 compiledata compiledict dictionary encoding intonation langopts numbers
  phoneme phonemelist readclause setlengths soundicon spect ssml synthdata synthesize tr_languages translate
  translateword voices wavegen speech espeak_api klatt"
ucd="case categories ctype proplist scripts tostring"

compile() { # sdk, target, source, object
  xcrun --sdk "$1" clang -c -O2 -target "$2" -isysroot "$(xcrun --sdk "$1" --show-sdk-path)" \
    -fPIC -fno-exceptions -fwrapv -w -DNDEBUG \
    -DLIBESPEAK_NG_EXPORT=1 -DN_PATH_HOME=1024 '-DPATH_ESPEAK_DATA=""' -include "$here/apple_endian.h" \
    -I"$here" -I"$src/src/include" -I"$src/src/include/compat" -I"$src/src/ucd-tools/src/include" \
    -I"$src/src/libespeak-ng" "$3" -o "$4"
}

slice() { # name, sdk, targets...
  name=$1 sdk=$2
  shift 2
  thin=""
  for target in "$@"; do
    objects="$work/obj/$name/$target"
    mkdir -p "$objects"
    for s in $library; do
      compile "$sdk" "$target" "$src/src/libespeak-ng/$s.c" "$objects/$s.o" &
    done
    for s in $ucd; do
      compile "$sdk" "$target" "$src/src/ucd-tools/src/$s.c" "$objects/ucd_$s.o" &
    done
    wait
    # wait does not report a failed compile; a missing object does.
    for s in $library; do [ -f "$objects/$s.o" ] || { echo "$s.c failed to compile for $target" >&2; exit 1; }; done
    for s in $ucd; do [ -f "$objects/ucd_$s.o" ] || { echo "$s.c failed to compile for $target" >&2; exit 1; }; done
    xcrun --sdk "$sdk" libtool -static -o "$objects/libespeak-ng.a" "$objects"/*.o
    thin="$thin $objects/libespeak-ng.a"
  done
  mkdir -p "$work/lib/$name"
  # shellcheck disable=SC2086
  xcrun lipo -create $thin -output "$work/lib/$name/libespeak-ng.a"
}

echo "Building eSpeak NG for macOS"
slice macos macosx arm64-apple-macos$macos_minimum x86_64-apple-macos$macos_minimum
echo "Building eSpeak NG for iOS"
slice ios iphoneos arm64-apple-ios$ios_minimum
slice ios-simulator iphonesimulator arm64-apple-ios$ios_minimum-simulator x86_64-apple-ios$ios_minimum-simulator

# Upstream's espeak-ng command, for this Mac only, to compile the data.
host=$(uname -m)
xcrun --sdk macosx clang -O2 -w -I"$here" -I"$src/src/include" "$src/src/espeak-ng.c" \
  "$work/obj/macos/$host-apple-macos$macos_minimum/libespeak-ng.a" -o "$work/espeak-ng"

echo "Compiling eSpeak NG's data ($dictionaries)"
data="$work/data/espeak-ng-data"
mkdir -p "$data/voices" "$work/dict"
cp -R "$src/phsource" "$work/data/phsource"
cp -R "$src/espeak-ng-data/voices/!v" "$data/voices/"
for d in $dictionaries; do
  found=$(cd "$src/espeak-ng-data" && find lang -type f \( -name "$d" -o -name "$d-*" \))
  if [ -z "$found" ]; then
    echo "eSpeak NG has no language files for '$d'" >&2
    exit 1
  fi
  for f in $found; do
    mkdir -p "$data/$(dirname "$f")"
    cp "$src/espeak-ng-data/$f" "$data/$f"
  done
done
espeak() { # directory, arguments...: runs the espeak-ng command, showing what it said only if it fails
  (cd "$1" && shift && ESPEAK_DATA_PATH="$work/data" "$work/espeak-ng" "$@" >"$work/log" 2>&1) || { cat "$work/log" >&2; exit 1; }
}
espeak "$work/data/phsource" --compile-intonations
espeak "$work/data/phsource" --compile-phonemes
for d in $dictionaries; do
  for f in "$src/dictsource/${d}_"* "$src/dictsource/extra/${d}_listx"; do
    [ -f "$f" ] && cp "$f" "$work/dict/"
  done
  espeak "$work/dict" --compile="$d"
  [ -f "$data/${d}_dict" ] || { echo "eSpeak NG did not compile the '$d' dictionary" >&2; exit 1; }
done
# Only needed to compile MBROLA voices, which this build leaves out.
rm -f "$data/phondata-manifest"

mkdir -p "$work/headers/espeak-ng"
cp "$src/src/include/espeak-ng/"*.h "$work/headers/espeak-ng/"
cp "$here/module.modulemap" "$work/headers/"

if [ "$what" != swift ]; then
  out="$package/native/ios/espeak-ng.xcframework"
  rm -rf "$out" "$package/native/espeak-ng-data"
  mkdir -p "$(dirname "$out")"
  xcodebuild -create-xcframework -output "$out" \
    -library "$work/lib/ios/libespeak-ng.a" -headers "$work/headers" \
    -library "$work/lib/ios-simulator/libespeak-ng.a" -headers "$work/headers" >/dev/null
  cp -R "$data" "$package/native/espeak-ng-data"
  echo "Built $out and $package/native/espeak-ng-data"
fi
if [ "$what" != dotnet ]; then
  out="$root/bindings/swift/Frameworks/espeak_ng.xcframework"
  resources="$root/bindings/swift/Sources/SpeechwarpVoiceEspeak/espeak-ng-data"
  rm -rf "$out" "$resources"
  mkdir -p "$(dirname "$out")" "$(dirname "$resources")"
  xcodebuild -create-xcframework -output "$out" \
    -library "$work/lib/ios/libespeak-ng.a" -headers "$work/headers" \
    -library "$work/lib/ios-simulator/libespeak-ng.a" -headers "$work/headers" \
    -library "$work/lib/macos/libespeak-ng.a" -headers "$work/headers" >/dev/null
  cp -R "$data" "$resources"
  echo "Built $out and $resources"
fi
