// swift-tools-version:5.9
import PackageDescription
import Foundation

/// SwiftPM records the deployment target (14.0) as the SDK version in every binary it links. macOS then treats
/// the program as built for macOS 14 and withholds newer behaviour: measured, Translation reports every language
/// as "not installed". Link with the real SDK version instead, keeping the deployment target.
let sdkVersion: String? = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && !output.isEmpty ? output : nil
}()
let realSDK: [LinkerSetting] = sdkVersion.map {
    [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", $0])]
} ?? []

let package = Package(
    name: "TextGrabber",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TextGrabberCore", targets: ["TextGrabberCore"]),
        .executable(name: "TextGrabber", targets: ["TextGrabber"]),
    ],
    targets: [
        .target(name: "TextGrabberCore"),
        .executableTarget(name: "TextGrabber", dependencies: ["TextGrabberCore"], linkerSettings: realSDK),
        .testTarget(name: "TextGrabberCoreTests", dependencies: ["TextGrabberCore"], resources: [.copy("Fixtures")],
                    linkerSettings: realSDK),
    ],
    swiftLanguageVersions: [.v5]
)
