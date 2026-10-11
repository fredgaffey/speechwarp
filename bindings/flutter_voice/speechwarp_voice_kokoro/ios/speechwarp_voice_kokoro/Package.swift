// swift-tools-version: 6.1
// The iOS side of speechwarp_voice_kokoro: the Swift library SpeechwarpVoiceKokoro (Kokoro-82M on ONNX Runtime's CPU)
// with the speechwarp package's trait "Kokoro" turned on, which fetches ONNX Runtime, and the provider class through
// which speechwarp_voice makes Kokoro voices. Swift 6.1 (Xcode 16.3) or later, for the trait.
//
// As in speechwarp_voice: from the repository itself in a checkout, from GitHub at this package's version otherwise.
// speechwarp_voice and speechwarp_voice_espeak ask for the trait too (see speechwarp_voice's Package.swift for why).

import Foundation
import PackageDescription

let speechwarpVersion = "0.3.7"

let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
let root = here.appendingPathComponent("../../../../..").standardizedFileURL
let inRepository = FileManager.default.fileExists(atPath: root.appendingPathComponent("include/speechwarp.h").path)

let package = Package(
    name: "speechwarp_voice_kokoro",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "speechwarp-voice-kokoro", targets: ["speechwarp_voice_kokoro"]),
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        inRepository
            ? .package(name: "Speechwarp", path: root.path, traits: ["Kokoro"])
            : .package(url: "https://github.com/fredgaffey/speechwarp", exact: Version(stringLiteral: speechwarpVersion),
                       traits: ["Kokoro"]),
    ],
    targets: [
        .target(
            name: "speechwarp_voice_kokoro",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "SpeechwarpVoiceKokoro", package: inRepository ? "Speechwarp" : "speechwarp"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
