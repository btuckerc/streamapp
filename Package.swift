// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let aecRoot = "\(packageRoot)/.build/aec"

let package = Package(
    name: "StreamApp",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "StreamApp", targets: ["StreamApp"])],
    targets: [
        .target(name: "EchoCancellation", publicHeadersPath: "include",
                cxxSettings: [
                    .define("NDEBUG"), .define("WEBRTC_POSIX"), .define("WEBRTC_MAC"),
                    .define("WEBRTC_LIBRARY_IMPL"), .define("WEBRTC_APM_DEBUG_DUMP", to: "0"),
                    .unsafeFlags(["-I\(aecRoot)/source/webrtc",
                                  "-I\(aecRoot)/source/subprojects/abseil-cpp-20240722.0"])
                ],
                linkerSettings: [.unsafeFlags(["\(aecRoot)/lib/libstreamapp_aec.a"]),
                                 .linkedFramework("Foundation")]),
        .target(name: "EncodedMuxer"),
        .executableTarget(name: "StreamApp", dependencies: ["EncodedMuxer", "EchoCancellation"], resources: [.process("Resources")], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ScreenCaptureKit"),
            .linkedFramework("CoreImage"), .linkedFramework("WebKit"),
            .linkedFramework("VideoToolbox"), .linkedFramework("Metal"),
            .linkedFramework("AVFoundation"), .linkedFramework("Security")
        ]),
        .testTarget(name: "StreamAppTests", dependencies: ["StreamApp"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
