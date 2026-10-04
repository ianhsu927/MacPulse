// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacPulse", targets: ["MacPulse"])],
    targets: [
        .executableTarget(name: "MacPulse", path: "Sources", linkerSettings: [
            .linkedFramework("IOKit"), .linkedLibrary("sqlite3")
        ]),
        .testTarget(name: "MacPulseTests", dependencies: ["MacPulse"], path: "Tests")
    ],
    swiftLanguageVersions: [.v5]
)
