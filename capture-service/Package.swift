// swift-tools-version: 5.9
import PackageDescription
import Foundation

let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Info.plist").path

let package = Package(
    name: "capture-service",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "capture-service", targets: ["capture-service"])],
    targets: [.executableTarget(name: "capture-service", linkerSettings: [
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                      "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
    ])]
)
