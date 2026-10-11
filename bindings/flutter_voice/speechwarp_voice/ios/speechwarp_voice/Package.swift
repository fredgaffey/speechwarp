// swift-tools-version: 6.1
// The iOS side of speechwarp_voice: a thin layer over the Swift library SpeechwarpVoice (the speechwarp package at the
// top of the repository), which does the reading. This plays what it reads through AVAudioEngine and reports the
// position to Dart.
//
// In a checkout of the repository (this package used by path, or as a git dependency) the library comes from the
// repository itself, so the plugin always builds against the Swift code beside it. In a copy from pub.dev, which
// holds only this package's folder, it comes from GitHub at the same version as this package.
//
// It asks for the speechwarp package's trait "Kokoro" although it uses nothing of Kokoro: Swift Package Manager fails
// to resolve the graph (ONNX Runtime "unresolved") when the first package to depend on speechwarp leaves the trait
// off and a later one, speechwarp_voice_kokoro, turns it on, and Flutter lists this package first. So Xcode downloads
// ONNX Runtime (about 60 MB, once) for every app with this package, but links it only into an app that also has
// speechwarp_voice_kokoro. Swift 6.1 (Xcode 16.3) or later, for the trait.

import Foundation
import PackageDescription

// The speechwarp release that goes with this version of the package.
let speechwarpVersion = "0.3.7"

// The repository's root, if this file is in a checkout of it (bindings/flutter_voice/speechwarp_voice/ios/speechwarp_voice). Flutter
// reaches the plugin through a symbolic link, so the path is resolved first.
let here = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
let root = here.appendingPathComponent("../../../../..").standardizedFileURL
let inRepository = FileManager.default.fileExists(atPath: root.appendingPathComponent("include/speechwarp.h").path)

let package = Package(
    name: "speechwarp_voice",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "speechwarp-voice", targets: ["speechwarp_voice"]),
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
            name: "speechwarp_voice",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "SpeechwarpVoice", package: inRepository ? "Speechwarp" : "speechwarp"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
