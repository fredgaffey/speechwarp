// swift-tools-version:6.1
// The Swift package. It is at the top of the repository because that is where Swift Package Manager looks,
// and because it compiles the C sources in src/ directly.
//
// Swift 6.1 (Xcode 16.3) or later reads this file, for its package trait; older toolchains read
// Package@swift-5.7.swift, which is the same without the Kokoro product. Keep the two in step.
import Foundation
import PackageDescription

let package = Package(
    name: "Speechwarp",
    // macOS 11, not 10.15, because ONNX Runtime's package (behind the Kokoro trait) asks for it, and Swift Package
    // Manager refuses a target whose minimum is below that of a package it uses. Package@swift-5.7.swift keeps 10.15.
    platforms: [.macOS(.v11), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "Speechwarp", targets: ["Speechwarp"]),
        // Optional: text read aloud by Apple's voices (Eloquence and the rest), sped up by speechwarp.
        .library(name: "SpeechwarpVoice", targets: ["SpeechwarpVoice"]),
        // Optional: Kokoro-82M, a neural voice, on ONNX Runtime's CPU (iOS and macOS). Its engine needs the trait
        // "Kokoro" below; without it the product holds only the catalogue of model files to download.
        .library(name: "SpeechwarpVoiceKokoro", targets: ["SpeechwarpVoiceKokoro"]),
    ],
    // Kokoro needs ONNX Runtime: about 60 MB to download and 200 MB unpacked. Swift Package Manager fetches every
    // binary of every package in the graph, used or not, so ONNX Runtime is behind a trait, off by default: only an
    // app that turns "Kokoro" on fetches it (`.package(url: ..., traits: ["Kokoro"])`, or Xcode's package list).
    traits: [
        .trait(name: "Kokoro", description: "Kokoro-82M on ONNX Runtime (SpeechwarpVoiceKokoro's engine). Fetches ONNX Runtime."),
    ],
    dependencies: [
        // 1.20.0 is the last release that asks for no more than iOS 13 and macOS 11; later ones ask for iOS 15 and
        // macOS 14, which would raise this whole package's minimum.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "CSpeechwarp",
            path: ".",
            // Everything here that is not this target's. Without it Swift Package Manager takes the example
            // apps of the other bindings for resources of this one.
            exclude: [
                "bindings", "examples", "tests", "tools", "docs", "cmake", "third_party", "listen",
                "CMakeLists.txt", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py", "MANIFEST.in",
                "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE", "NOTICE",
                "src/internal.h", "src/rename.h", "src/fft.h",
            ],
            sources: [
                "src/speechwarp.c",
                "src/fft.c",
                "src/trainer.c",
                "src/third_party_kissfft.c",
                "src/third_party_sonic.c",
                "src/third_party_speedy.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("third_party/kissfft"),
                // Upstream is full of assertions.
                .define("NDEBUG"),
            ]
        ),
        .target(
            name: "Speechwarp",
            dependencies: ["CSpeechwarp"],
            path: "bindings/swift/Sources/Speechwarp"
        ),
        .target(
            name: "SpeechwarpVoice",
            dependencies: ["Speechwarp"],
            path: "bindings/swift/Sources/SpeechwarpVoice"
        ),
        .target(
            name: "SpeechwarpVoiceKokoro",
            dependencies: [
                "SpeechwarpVoice",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager",
                         condition: .when(platforms: [.macOS, .iOS], traits: ["Kokoro"])),
            ],
            path: "bindings/swift/Sources/SpeechwarpVoiceKokoro"
        ),
        .testTarget(
            name: "SpeechwarpVoiceKokoroTests",
            dependencies: ["SpeechwarpVoiceKokoro"],
            path: "bindings/swift/Tests/SpeechwarpVoiceKokoroTests"
        ),
        .testTarget(
            name: "SpeechwarpVoiceTests",
            dependencies: ["SpeechwarpVoice"],
            path: "bindings/swift/Tests/SpeechwarpVoiceTests"
        ),
        .testTarget(
            name: "SpeechwarpTests",
            dependencies: ["Speechwarp"],
            path: "bindings/swift/Tests/SpeechwarpTests"
        ),
    ],
    // The sources are Swift 5, as they were before this file needed Swift 6.1's manifest.
    swiftLanguageModes: [.v5]
)

// Optional: speech to text with whisper.cpp (SpeechwarpListen). whisper.cpp is a submodule that is not fetched by
// default and needs CMake's per-architecture settings, so its library is a binary framework that
// bindings/swift/build-listen-xcframework.sh builds. The product exists only once it has been built: a target whose
// files are missing would break the whole package. Swift Package Manager caches this file's result, so run
// `swift package purge-cache` after building or deleting the framework. See bindings/swift/README.md.
let listenFramework = "bindings/swift/Frameworks/speechwarp_listen.xcframework"
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + listenFramework) {
    package.products.append(.library(name: "SpeechwarpListen", targets: ["SpeechwarpListen"]))
    package.targets += [
        .binaryTarget(name: "speechwarp_listen", path: listenFramework),
        .target(
            name: "SpeechwarpListen",
            dependencies: [
                "Speechwarp",
                .target(name: "speechwarp_listen", condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "bindings/swift/Sources/SpeechwarpListen"
        ),
        .testTarget(
            name: "SpeechwarpListenTests",
            dependencies: ["SpeechwarpListen"],
            path: "bindings/swift/Tests/SpeechwarpListenTests"
        ),
    ]
    // Kokoro's tests check with whisper.cpp that the words can be heard.
    package.targets.first { $0.name == "SpeechwarpVoiceKokoroTests" }?.dependencies.append("SpeechwarpListen")
}

// Optional: eSpeak NG's voices and phonemes (SpeechwarpVoiceEspeak). LICENSED UNDER THE GPL-3.0-OR-LATER, unlike the
// rest of this package: an app that uses this product must be distributed under the GPL-3.0 too. eSpeak NG is a
// submodule that is not fetched by default; its library is a binary framework, and its data a resource folder, that
// `bindings/dotnet/Speechwarp.Voice.Espeak/native-build/build-espeak.sh swift` builds. As with SpeechwarpListen, the
// product exists only once they have been built (then run `swift package purge-cache`).
let espeakFramework = "bindings/swift/Frameworks/espeak_ng.xcframework"
let espeakData = "bindings/swift/Sources/SpeechwarpVoiceEspeak/espeak-ng-data"
if FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + espeakFramework),
   FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + espeakData) {
    package.products.append(.library(name: "SpeechwarpVoiceEspeak", targets: ["SpeechwarpVoiceEspeak"]))
    package.targets += [
        .binaryTarget(name: "espeak_ng", path: espeakFramework),
        .target(
            name: "SpeechwarpVoiceEspeak",
            dependencies: [
                "SpeechwarpVoice",
                .target(name: "espeak_ng", condition: .when(platforms: [.macOS, .iOS])),
            ],
            path: "bindings/swift/Sources/SpeechwarpVoiceEspeak",
            resources: [.copy("espeak-ng-data")]
        ),
        .testTarget(
            name: "SpeechwarpVoiceEspeakTests",
            dependencies: ["SpeechwarpVoiceEspeak"],
            path: "bindings/swift/Tests/SpeechwarpVoiceEspeakTests"
        ),
    ]
}

// Kokoro on the GPU (MLX) is a separate Swift package, bindings/swift/KokoroGPU, which builds the framework that the
// Speechwarp.Voice.Kokoro.Gpu NuGet package carries. It is not a product here: it would make every user of this package
// fetch MLX. Swift apps can use mlalma/kokoro-ios directly, behind a SentenceVoice of their own.
