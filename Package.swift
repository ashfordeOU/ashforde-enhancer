// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AshfordeEnhancer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AshfordeEnhancer", targets: ["AshfordeEnhancer"]),
        .executable(name: "ashforde-fan", targets: ["ashforde-fan"]),
        .library(name: "EnhancerCore", targets: ["EnhancerCore"]),
    ],
    targets: [
        .target(name: "EnhancerCore"),
        .executableTarget(name: "AshfordeEnhancer", dependencies: ["EnhancerCore"]),
        // The fan helper: installed as /Library/PrivilegedHelperTools/ashforde-fan (root:wheel, 0755).
        .executableTarget(name: "ashforde-fan", dependencies: ["EnhancerCore"]),
        .testTarget(name: "EnhancerCoreTests", dependencies: ["EnhancerCore"]),
    ]
)
