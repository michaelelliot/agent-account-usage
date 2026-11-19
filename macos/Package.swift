// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SubSmasher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SubSmasher", targets: ["SubSmasher"])
    ],
    targets: [
        .target(name: "SubSmasherCore"),
        .executableTarget(name: "SubSmasher", dependencies: ["SubSmasherCore"]),
        .testTarget(name: "SubSmasherCoreTests", dependencies: ["SubSmasherCore"]),
        .testTarget(name: "SubSmasherTests", dependencies: ["SubSmasher", "SubSmasherCore"]),
    ]
)
