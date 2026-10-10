// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EgoKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EgoKit", targets: ["EgoKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "EgoKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows, .android])),
                "EgoWalletCore",
            ]
        ),
        // Ego Desktop's other-chain key and address code (crates/ego-wallet-core),
        // built and checked against Ego Desktop by the Wallet Core workflow in
        // ego-blockchain-, and published there as a pre-release.
        .binaryTarget(
            name: "EgoWalletCore",
            url: "https://github.com/ego-blockchain/ego-blockchain-/releases/download/wallet-core-0.2.0/EgoWalletCore.xcframework.zip",
            checksum: "6395b0b805d47445c02f0335160dc1285f3a03e390dd4eceb6d510e88782fb06"
        ),
        .testTarget(name: "EgoKitTests", dependencies: ["EgoKit"]),
    ]
)
