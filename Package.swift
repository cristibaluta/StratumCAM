// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StratumCAM",
    products: [
        .library(
            name: "StratumCAM",
            targets: ["StratumCAM"]
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
        .testTarget(
            name: "StratumCAMTests",
            dependencies: [
                "StratumCAM",
                .product(name: "SwiftDXF", package: "SwiftDXF")
            ]
        )
    ]
)
