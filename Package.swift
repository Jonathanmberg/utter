// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Utter", path: "Sources/Utter")
    ]
)
