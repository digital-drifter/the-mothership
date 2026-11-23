// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mothership",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MothershipCore", targets: ["MothershipCore"]),
        .executable(name: "Mothership", targets: ["Mothership"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.99.3"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
    ],
    targets: [
        .target(name: "MothershipCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "Mothership", dependencies: [
            "MothershipCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
        .testTarget(name: "MothershipCoreTests", dependencies: ["MothershipCore"]),
        .testTarget(name: "MothershipTests", dependencies: [
            "Mothership",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
    ]
)
