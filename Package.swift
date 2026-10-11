// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CRTOverlay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CRTOverlay",
            path: "Sources/CRTOverlay"
        )
    ]
)
