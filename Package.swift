// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ContainerCompose",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "ContainerComposeCore", targets: ["ContainerComposeCore"]),
        .executable(name: "container-compose", targets: ["ContainerComposeCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")
    ],
    targets: [
        .target(
            name: "ContainerComposeCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .executableTarget(
            name: "ContainerComposeCLI",
            dependencies: [
                "ContainerComposeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "ContainerComposeCoreTests",
            dependencies: ["ContainerComposeCore"]
        )
    ]
)
