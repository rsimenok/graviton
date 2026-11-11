// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Graviton",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Graviton", targets: ["Graviton"])
    ],
    targets: [
        .executableTarget(
            name: "Graviton",
            path: "Sources/Graviton",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "GravitonTests",
            dependencies: ["Graviton"],
            path: "Tests/GravitonTests"
        )
    ]
)
