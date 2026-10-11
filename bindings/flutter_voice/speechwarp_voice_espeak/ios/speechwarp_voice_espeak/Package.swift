// swift-tools-version: 6.1
// The iOS side of speechwarp_voice_espeak (GPL-3.0-or-later): the Swift library SpeechwarpVoiceEspeak (eSpeak NG and
// its English data) and the provider class through which speechwarp_voice makes eSpeak voices and Kokoro gets its
// phonemizer.
//
// The speechwarp package has the SpeechwarpVoiceEspeak product only once eSpeak NG's framework and data have been
// built in a checkout of the repository (`bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh
// swift`; see docs/voices.md). So on iOS this package works from a checkout where they have been built. Anywhere
// else (a copy from pub.dev, or a checkout without the build) it builds without eSpeak: the provider is still there
// but every eSpeak voice fails with an error that says why, and Kokoro finds no phonemizer. Android is not affected:
// there the library comes from Maven Central.
//
// It asks for the trait "Kokoro", as speechwarp_voice does and for the same reason (see its Package.swift).

import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
let root = here.appendingPathComponent("../../../../..").standardizedFileURL
func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
let espeakBuilt = exists("include/speechwarp.h") && exists("bindings/swift/Frameworks/espeak_ng.xcframework")
    && exists("bindings/swift/Sources/SpeechwarpVoiceEspeak/espeak-ng-data")

let package = Package(
    name: "speechwarp_voice_espeak",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "speechwarp-voice-espeak", targets: ["speechwarp_voice_espeak"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
    ] + (espeakBuilt ? [.package(name: "Speechwarp", path: root.path, traits: ["Kokoro"])] : []),
    targets: [
        .target(
            name: "speechwarp_voice_espeak",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ] + (espeakBuilt ? [.product(name: "SpeechwarpVoiceEspeak", package: "Speechwarp")] : []),
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: espeakBuilt ? [.define("SPEECHWARP_ESPEAK")] : []
        ),
    ],
    swiftLanguageModes: [.v5]
)
