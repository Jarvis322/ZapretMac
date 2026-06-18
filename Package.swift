// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZapretMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ZapretMac", path: "Sources")
    ]
)
