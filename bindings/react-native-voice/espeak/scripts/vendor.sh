#!/bin/sh
# Copies into this package what its iOS build uses from elsewhere in the repository: the Swift package's eSpeak sources
# (bindings/swift/Sources/SpeechwarpVoiceEspeak), eSpeak NG's library as an xcframework and its English data, both
# built by `bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift` (which needs the submodule
# third_party/espeak-ng), and eSpeak NG's licence. Runs before packing (`yarn prepare`); nothing copied is committed.
# Android needs no copy: it uses the Maven artifact io.github.fredgaffey:speechwarp-voice-espeak.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../../.." && pwd)

# Installed from npm: the copies are already in the package.
[ -f "$root/include/speechwarp.h" ] || exit 0

framework="$root/bindings/swift/Frameworks/espeak_ng.xcframework"
data="$root/bindings/swift/Sources/SpeechwarpVoiceEspeak/espeak-ng-data"
if [ ! -d "$framework" ] || [ ! -d "$data" ]; then
  echo "eSpeak NG is not built for iOS. Run:" >&2
  echo "  git submodule update --init --checkout third_party/espeak-ng" >&2
  echo "  bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift" >&2
  exit 1
fi

out="$here/ios/vendor"
rm -rf "$out"
mkdir -p "$out/Frameworks"
cp "$root"/bindings/swift/Sources/SpeechwarpVoiceEspeak/*.swift "$out/"
# Only the iOS slices: the macOS one would double the size of the package for nothing.
mkdir -p "$out/Frameworks/espeak_ng.xcframework"
cp "$framework/Info.plist" "$out/Frameworks/espeak_ng.xcframework/"
for slice in "$framework"/ios-*; do cp -R "$slice" "$out/Frameworks/espeak_ng.xcframework/"; done
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$out/Frameworks/espeak_ng.xcframework/Info.plist" >/dev/null 2>&1 &&
  python3 - "$out/Frameworks/espeak_ng.xcframework/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['AvailableLibraries'] = [l for l in info['AvailableLibraries'] if l.get('SupportedPlatform') == 'ios']
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
cp -R "$data" "$out/espeak-ng-data"

cp "$root/third_party/espeak-ng/COPYING" "$here/COPYING"
cp "$root/NOTICE" "$here/NOTICE"
