// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalMeetingTranscriber",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "LocalMeetingTranscriber", targets: ["LocalMeetingTranscriber"])
    ],
    targets: [
        .target(
            name: "TranscriberCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "LocalMeetingTranscriber",
            dependencies: ["TranscriberCore"]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: ["TranscriberCore"]
        )
    ]
)
