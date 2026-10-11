#!/bin/sh
# Copies into this package what its iOS build compiles from elsewhere in the repository: the C library (as
# bindings/react-native does) and the Swift sources of the reader (bindings/swift/Sources/Speechwarp and
# SpeechwarpVoice). An npm package holds only its own folder, so it cannot reach them where they are. Runs before
# packing (`yarn prepare`); the copies are not committed. Android needs no copy: it uses the Maven artifacts.
#
# CocoaPods compiles every Swift file of a pod into one module, here SpeechwarpVoice, so the copies' `import
# Speechwarp` (a module of its own in Swift Package Manager) is dropped, and `import CSpeechwarp` made
# implementation-only. Nothing else in them changes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../.." && pwd)

# Installed from npm: the copies are already in the package and there is no repository to copy from.
[ -f "$root/include/speechwarp.h" ] || exit 0

out="$here/cpp/speechwarp"
rm -rf "$out"
mkdir -p "$out/include" "$out/src" "$out/licenses"
cp "$root/include/speechwarp.h" "$out/include/"
cp "$root"/src/*.c "$root"/src/*.h "$out/src/"
mkdir -p "$out/third_party"
for lib in speedy sonic kissfft; do cp -R "$root/third_party/$lib" "$out/third_party/$lib"; done
cp "$root/third_party/README.md" "$out/third_party/" 2>/dev/null || true
cp "$root/LICENSE" "$root/NOTICE" "$out/licenses/"
# Swift sees the C library as the module CSpeechwarp, as in Package.swift.
cat > "$out/include/module.modulemap" <<'MAP'
module CSpeechwarp {
    header "speechwarp.h"
    export *
}
MAP

swift="$here/ios/vendor"
rm -rf "$swift"
mkdir -p "$swift"
# Implementation-only, so that the engine pods, which import SpeechwarpVoice, need not find CSpeechwarp too.
sed 's/^import CSpeechwarp$/@_implementationOnly import CSpeechwarp/' \
  "$root/bindings/swift/Sources/Speechwarp/SpeechwarpStream.swift" > "$swift/SpeechwarpStream.swift"
# The reader and Apple's voices; not the speech-to-text half of SpeechwarpVoice, which needs the Speech framework
# and the microphone.
for file in SentenceVoice VoicedText VoiceCache SpokenText AppleSentenceVoice SpeechRenderer SpeechVoice AudioConversion; do
  sed '/^import Speechwarp$/d' "$root/bindings/swift/Sources/SpeechwarpVoice/$file.swift" > "$swift/$file.swift"
done

# The package's own licence files, which npm and licence scanners look for at the top of the package.
cp "$root/LICENSE" "$root/NOTICE" "$here/"
