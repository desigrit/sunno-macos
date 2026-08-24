// swift-tools-version: 5.9
import PackageDescription

// A standalone executable rather than a dependency of the app target, for two reasons. It can
// be built with the Command Line Tools alone, so the engine does not become the one part of the
// project that needs Xcode; and while the speech pipeline is still Python, the decode has to be
// reachable from Python, which a library linked into the app is not.
let package = Package(
    name: "whisperkit-service",
    platforms: [.macOS(.v13)],
    dependencies: [
        // WhisperKit lives here now: argmaxinc/WhisperKit redirects to this repository, which
        // also carries SpeakerKit and TTSKit. MIT, and it declares macOS 13, which means the
        // app's 13.3 floor survives the engine change. docs/MACOS-PORT.md assumed macOS 14 was
        // forced by WhisperKit's minimum; that is no longer the case.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisperkit-service",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
    ]
)
