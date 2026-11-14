// swift-tools-version: 5.10

import Foundation
import PackageDescription

// CommandLineTools without Xcode ships TestingMacros under plugins/testing/ instead of plugins/,
// which SwiftPM's default swiftbuild system does not pass to swift-frontend automatically.
let cltTestingPluginDir = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let cltTestingMacros = "\(cltTestingPluginDir)/libTestingMacros.dylib"
let xcodePath = "/Applications/Xcode.app"
let useCLTTestingPlugin = !FileManager.default.fileExists(atPath: xcodePath)
    && FileManager.default.fileExists(atPath: cltTestingMacros)
let testSwiftSettings: [SwiftSetting] = useCLTTestingPlugin
    ? [.unsafeFlags(["-plugin-path", cltTestingPluginDir])]
    : []

let package = Package(
    name: "CampusEntry",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CampusEntryCore",
            targets: ["CampusEntryCore"]
        ),
        .executable(
            name: "CampusEntry",
            targets: ["CampusEntry"]
        )
    ],
    targets: [
        .target(
            name: "CampusEntryCore",
            resources: [
                .copy("Resources/js")
            ]
        ),
        .executableTarget(
            name: "CampusEntry",
            dependencies: ["CampusEntryCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .testTarget(
            name: "CampusEntryCoreTests",
            dependencies: ["CampusEntryCore"],
            swiftSettings: testSwiftSettings
        )
    ]
)
