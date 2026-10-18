// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StratumCAM",
    platforms: [
        .macOS(.v13),
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "StratumCAM",
            targets: ["StratumCAM"]
        ),
        .executable(
            name: "StratumCAMDemo",
            targets: ["StratumCAMDemo"]
        )
    ],
    targets: [
        .target(
            name: "StratumCAM"
        ),
        .executableTarget(
            name: "StratumCAMDemo",
            dependencies: [
                "StratumCAM"
            ],
            resources: [
                .process("Sources/StratumCAMDemo/Shaders.metal")
            ]
        ),
        .testTarget(
            name: "StratumCAMTests",
            dependencies: [
                "StratumCAM"
            ]
        )
    ]
)
