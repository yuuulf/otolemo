// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Otolemo",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Otolemo", targets: ["Otolemo"])
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Otolemo",
            dependencies: ["TranscriberCore"]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        )
    ]
)
