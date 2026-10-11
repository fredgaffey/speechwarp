#!/bin/sh
# Builds Kokoro on the GPU for iPhones: SpeechwarpKokoroGPU.framework (mlalma/kokoro-ios on MLX Swift, misaki's
# pronunciations from mlalma/MisakiSwift, and the C interface in Sources/) plus the four resource bundles it reads at
# run time (MLX's shaders, Kokoro's configuration, misaki's dictionaries, ZIPFoundation's privacy manifest), and puts
# them where the NuGet package looks for them:
#   ../../dotnet/Speechwarp.Voice.Kokoro.Gpu/native/ios-arm64/   (or the directory given as the first argument)
# about 45 MB, never committed. Devices only: MLX needs a real GPU, and the package does not reference it in
# simulator builds.
#
# Needs Xcode with its Metal toolchain (`xcrun -f metal` finds it; if not: xcodebuild -downloadComponent MetalToolchain)
# and network access for the first build (git clones and Swift packages).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=${1:-"$root/bindings/dotnet/Speechwarp.Voice.Kokoro.Gpu/native/ios-arm64"}

# Pinned sources, compiled as targets of Package.swift. Change both together with Package.swift's mlx-swift and
# MLXUtilsLibrary versions, which must match what these two require.
kokoro_url=https://github.com/mlalma/kokoro-ios.git
kokoro_commit=4d6d1d8ff8cd012014180c9cd4cf0151e7682354    # tag 1.0.11
misaki_url=https://github.com/mlalma/MisakiSwift.git
misaki_commit=6835a1ce4a8854075c89f18ff75c74b13ef58e15    # tag 1.0.6

if ! xcrun -f metal >/dev/null 2>&1; then
  echo "Xcode's Metal toolchain is missing: run xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

fetch() { # url, commit, directory
  if [ "$(git -C "$3" rev-parse HEAD 2>/dev/null || true)" != "$2" ]; then
    rm -rf "$3"
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
  fi
}
mkdir -p "$here/Vendor"
fetch "$kokoro_url" "$kokoro_commit" "$here/Vendor/kokoro-ios"
fetch "$misaki_url" "$misaki_commit" "$here/Vendor/MisakiSwift"

work="$here/.build/xcode"
rm -rf "$work/ios.xcarchive"
(cd "$here" && xcodebuild archive -scheme SpeechwarpKokoroGPU -destination 'generic/platform=iOS' \
  -archivePath "$work/ios.xcarchive" -derivedDataPath "$work/dd" -configuration Release \
  SKIP_INSTALL=NO CODE_SIGNING_ALLOWED=NO -quiet)

products="$work/dd/Build/Intermediates.noindex/ArchiveIntermediates/SpeechwarpKokoroGPU/BuildProductsPath/Release-iphoneos"
rm -rf "$out"
mkdir -p "$out"
cp -RL "$work/ios.xcarchive/Products/usr/local/lib/SpeechwarpKokoroGPU.framework" "$out/"
for bundle in "$products"/*.bundle; do
  cp -RL "$bundle" "$out/"
done
# Xcode names the framework after the folder (kokorogpu.SpeechwarpKokoroGPU, version 1.0); give it speechwarp's.
version=$(sed -n 's/^#define SPEECHWARP_VERSION "\(.*\)"$/\1/p' "$root/include/speechwarp.h")
[ -n "$version" ] || { echo "SPEECHWARP_VERSION not found in include/speechwarp.h" >&2; exit 1; }
plist="$out/SpeechwarpKokoroGPU.framework/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.fredgaffey.speechwarp.KokoroGPU" \
  -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" "$plist"

# The licences of everything compiled in travel with it.
licences="$out/licenses"
mkdir -p "$licences"
checkouts="$work/dd/SourcePackages/checkouts"
cp "$here/Vendor/kokoro-ios/LICENSE" "$licences/kokoro-ios.txt"
cp "$here/Vendor/MisakiSwift/LICENSE" "$licences/MisakiSwift.txt"
cp "$checkouts/mlx-swift/LICENSE" "$licences/mlx-swift.txt"
cp "$checkouts/MLXUtilsLibrary/LICENSE" "$licences/MLXUtilsLibrary.txt"
cp "$checkouts/swift-numerics/LICENSE.txt" "$licences/swift-numerics.txt"
cp "$checkouts/ZIPFoundation/LICENSE" "$licences/ZIPFoundation.txt"

frameworks=$(find "$out" -maxdepth 1 -name '*.framework' | wc -l | tr -d ' ')
bundles=$(find "$out" -maxdepth 1 -name '*.bundle' | wc -l | tr -d ' ')
if [ "$frameworks" != 1 ] || [ "$bundles" != 4 ]; then
  echo "Expected one framework and four bundles, built $frameworks and $bundles in $out" >&2
  exit 1
fi
echo "Kokoro GPU: $(du -sh "$out" | cut -f1) in $out"
