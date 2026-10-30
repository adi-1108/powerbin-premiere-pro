// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowerBin",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PowerBin", targets: ["PowerBin"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PowerBin",
            dependencies: [],
            path: "Sources/PowerBinPersonal"
        ),
        .testTarget(
            name: "PowerBinTests",
            dependencies: ["PowerBin"],
            path: "Tests"
        ),
    ]
)
