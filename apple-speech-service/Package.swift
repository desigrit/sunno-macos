// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-speech-service",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "apple-speech-service")],
    swiftLanguageModes: [.v5]
)
