// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "audio-capture",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "audio-capture")
    ]
)
