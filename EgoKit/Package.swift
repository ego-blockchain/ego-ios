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
            url: "https://github.com/ego-blockchain/ego-blockchain-/releases/download/wallet-core-0.3.0/EgoWalletCore-0.5.0.xcframework.zip",
            checksum: "91b078162e938383b7bbc5fa2f5fffc4bb827f49e60be4cc250c10ddae344561"
        ),
        .testTarget(name: "EgoKitTests", dependencies: ["EgoKit"]),
    ]
)
