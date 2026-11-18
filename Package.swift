// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TextGrabber",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextGrabberCore", targets: ["TextGrabberCore"]),
        .executable(name: "TextGrabber", targets: ["TextGrabber"]),
    ],
    targets: [
        .target(name: "TextGrabberCore"),
        .executableTarget(name: "TextGrabber", dependencies: ["TextGrabberCore"]),
        .testTarget(name: "TextGrabberCoreTests", dependencies: ["TextGrabberCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageVersions: [.v5]
)
