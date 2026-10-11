// swift-tools-version: 6.2
// Kokoro on the iPhone's GPU through MLX, as one framework with a C interface, for apps not written in Swift (the
// Speechwarp.Voice.Kokoro.Gpu NuGet package). Not part of the repository's main Swift package: build it with
// build-frameworks.sh, which first fetches the two vendored sources below at pinned commits into Vendor/ (not in git).
//
// kokoro-ios (Kokoro-82M ported to MLX Swift) and MisakiSwift (misaki's English pronunciations) are compiled here as
// targets, not used as their packages' products, because both products are dynamic libraries: used as products they
// split the build into eight frameworks, three of them named after hashes. Compiled here, everything links into one
// framework, SpeechwarpKokoroGPU.framework, beside four resource bundles. The versions match kokoro-ios 1.0.11's own
// exact requirements; Package.resolved pins the rest.

import PackageDescription

let package = Package(
  name: "SpeechwarpKokoroGPU",
  platforms: [
    .iOS(.v18), .macOS(.v15),
  ],
  products: [
    .library(name: "SpeechwarpKokoroGPU", type: .dynamic, targets: ["SpeechwarpKokoroGPU"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.30.2"),
    .package(url: "https://github.com/mlalma/MLXUtilsLibrary.git", exact: "0.0.6"),
  ],
  targets: [
    // The C interface (kokoro_gpu_*), the only part of this that is speechwarp's own code.
    .target(
      name: "SpeechwarpKokoroGPU",
      dependencies: [
        "KokoroSwift",
        .product(name: "MLX", package: "mlx-swift"),
      ]
    ),
    // github.com/mlalma/kokoro-ios, MIT; the commit is in build-frameworks.sh.
    .target(
      name: "KokoroSwift",
      dependencies: [
        "MisakiSwift",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"),
        .product(name: "MLXFFT", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
      ],
      path: "Vendor/kokoro-ios/Sources/KokoroSwift",
      resources: [.copy("../../Resources/")]
    ),
    // github.com/mlalma/MisakiSwift, Apache-2.0; the commit is in build-frameworks.sh.
    .target(
      name: "MisakiSwift",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXUtilsLibrary", package: "MLXUtilsLibrary"),
      ],
      path: "Vendor/MisakiSwift/Sources/MisakiSwift",
      resources: [.copy("../../Resources/")]
    ),
  ]
)
