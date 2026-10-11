#!/bin/sh
# Copies the Swift package's Kokoro sources (bindings/swift/Sources/SpeechwarpVoiceKokoro) into this package for its iOS
# build. An npm package holds only its own folder. Runs before packing (`yarn prepare`); the copy is not committed.
# Android needs no copy: it uses the Maven artifact io.github.fredgaffey:speechwarp-voice-kokoro.
#
# The engine is compiled only with the condition Kokoro (the Swift package's trait), and imports ONNX Runtime as the
# Swift package names it, OnnxRuntimeBindings; the CocoaPod of the same library is the module onnxruntime_objc, so
# the copies say that instead. Nothing else in them changes.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/../../.." && pwd)

# Installed from npm: the copies are already in the package.
[ -f "$root/include/speechwarp.h" ] || exit 0

out="$here/ios/vendor"
rm -rf "$out"
mkdir -p "$out"
for file in "$root"/bindings/swift/Sources/SpeechwarpVoiceKokoro/*.swift; do
  sed -e 's/canImport(OnnxRuntimeBindings)/canImport(onnxruntime_objc)/' \
      -e 's/^import OnnxRuntimeBindings$/import onnxruntime_objc/' "$file" > "$out/$(basename "$file")"
done

cp "$root/LICENSE" "$root/NOTICE" "$here/"
