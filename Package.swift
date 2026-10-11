// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacCRT",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacCRT", targets: ["MacCRT"])
    ],
    targets: [
        .executableTarget(
            name: "MacCRT",
            path: "Sources/MacCRT"
        )
    ]
)
