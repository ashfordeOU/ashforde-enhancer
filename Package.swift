// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AshfordeEnhancer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AshfordeEnhancer", targets: ["AshfordeEnhancer"]),
        .library(name: "EnhancerCore", targets: ["EnhancerCore"]),
    ],
    targets: [
        .target(name: "EnhancerCore"),
        .executableTarget(name: "AshfordeEnhancer", dependencies: ["EnhancerCore"]),
        .testTarget(name: "EnhancerCoreTests", dependencies: ["EnhancerCore"]),
    ]
)
