// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-audio-tap",
    // Core Audio process taps (CATapDescription, AudioHardwareCreateProcessTap) need macOS 14.4.
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "SystemAudioTap", targets: ["SystemAudioTap"]),
        .executable(name: "audio-tap", targets: ["audio-tap"]),
    ],
    targets: [
        .target(name: "SystemAudioTap"),
        .executableTarget(name: "audio-tap", dependencies: ["SystemAudioTap"]),
        .testTarget(name: "SystemAudioTapTests", dependencies: ["SystemAudioTap"]),
    ]
)
