// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lapwy",
    // iOS is what it is made for. macOS is there so that `swift test` runs on a Mac.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Lapwy", targets: ["Lapwy"]),
    ],
    targets: [
        .target(
            name: "Lapwy",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "LapwyTests", dependencies: ["Lapwy"]),
    ]
)
