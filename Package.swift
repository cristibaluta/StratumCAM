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
    dependencies: [
        .package(url: "https://github.com/SecondMouseAU/SwiftDXF.git", from: "0.2.1")
    ],
    targets: [
        .target(
            name: "StratumCAM",
            dependencies: [
                .product(name: "SwiftDXF", package: "SwiftDXF")
            ]
        ),
        .executableTarget(
            name: "StratumCAMDemo",
            dependencies: [
                "StratumCAM",
                .product(name: "SwiftDXF", package: "SwiftDXF")
            ],
            resources: [
                .process("Sources/StratumCAMDemo/Shaders.metal")
            ]
        ),
        .testTarget(
            name: "StratumCAMTests",
            dependencies: [
                "StratumCAM",
                .product(name: "SwiftDXF", package: "SwiftDXF")
            ]
        )
    ]
)
