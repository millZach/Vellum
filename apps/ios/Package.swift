// swift-tools-version: 6.0
import PackageDescription

// VellumCore holds everything Vellum can test without a device: today the app's identity and its tabs; later the
// canvas model, canvas units, sheet placement and the job format sent to Sotto. Keep SwiftUI and UIKit out of it, so
// `swift test` runs on a macOS runner and on Forge's Linux Swift alike.
let package = Package(
    name: "VellumCore",
    platforms: [.iOS("27.1"), .macOS(.v14)],
    products: [.library(name: "VellumCore", targets: ["VellumCore"])],
    targets: [
        .target(name: "VellumCore"),
        .testTarget(name: "VellumCoreTests", dependencies: ["VellumCore"]),
    ]
)
