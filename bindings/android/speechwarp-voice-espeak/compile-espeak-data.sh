#!/bin/sh
# Compiles eSpeak NG's data from the third_party/espeak-ng submodule, as upstream's Makefile does it and as
# bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh does for Apple systems, with upstream's own
# espeak-ng command built for this computer (the Gradle build makes it from src/main/cpp/CMakeLists.txt).
#
#   compile-espeak-data.sh ESPEAK_NG_COMMAND OUTPUT
#
# writes OUTPUT/espeak-ng-data. Only the dictionaries named in ESPEAK_DICTIONARIES are compiled (default "en", about
# 1.2 MB with English's accents and every voice variant); each needs its lang/ files, which are those named after it
# ("en", "en-GB-scotland" and so on). For example: ESPEAK_DICTIONARIES="en de fr".
set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 ESPEAK_NG_COMMAND OUTPUT" >&2
  exit 2
fi
command=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
mkdir -p "$2"
out=$(cd "$2" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../.." && pwd)/third_party/espeak-ng
dictionaries=${ESPEAK_DICTIONARIES:-en}
if [ ! -f "$src/phsource/phonemes" ]; then
  echo "eSpeak NG's source is missing. Fetch it with:" >&2
  echo "  git submodule update --init --checkout third_party/espeak-ng" >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

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
  (cd "$1" && shift && ESPEAK_DATA_PATH="$work/data" "$command" "$@" >"$work/log" 2>&1) || { cat "$work/log" >&2; exit 1; }
}
espeak "$work/data/phsource" --compile-intonations
espeak "$work/data/phsource" --compile-phonemes
for d in $dictionaries; do
  for f in "$src/dictsource/${d}_"* "$src/dictsource/extra/${d}_listx"; do
    if [ -f "$f" ]; then cp "$f" "$work/dict/"; fi
  done
  espeak "$work/dict" --compile="$d"
  [ -f "$data/${d}_dict" ] || { echo "eSpeak NG did not compile the '$d' dictionary" >&2; exit 1; }
done
# Only needed to compile MBROLA voices, which this build leaves out.
rm -f "$data/phondata-manifest"

rm -rf "$out/espeak-ng-data"
cp -R "$data" "$out/espeak-ng-data"
