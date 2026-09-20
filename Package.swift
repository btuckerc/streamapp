// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamApp",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "StreamApp", targets: ["StreamApp"])],
    targets: [
        .systemLibrary(name: "CFFmpeg", pkgConfig: "libavformat", providers: [.brew(["ffmpeg"])]),
        .target(name: "EncodedMuxer", dependencies: ["CFFmpeg"]),
        .executableTarget(name: "StreamApp", dependencies: ["EncodedMuxer"], resources: [.process("Resources")], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("CoreImage"), .linkedFramework("WebKit"),
            .linkedFramework("VideoToolbox"), .linkedFramework("Metal"),
            .linkedFramework("AVFoundation"), .linkedFramework("Security")
        ]),
        .testTarget(name: "StreamAppTests", dependencies: ["StreamApp"])
    ],
    swiftLanguageModes: [.v5]
)
