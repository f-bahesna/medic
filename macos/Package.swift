// swift-tools-version:5.9
// Medic.app: medic's menu bar monitor for CPU, memory and disk. Built into an
// app bundle and a DMG by tools/macapp.sh; see macos/README.md.
import PackageDescription

let package = Package(
    name: "MedicBar",
    platforms: [.macOS(.v11)],
    targets: [
        // Reading and formatting the numbers, without AppKit, so it can be tested.
        .target(name: "MedicBarCore"),
        // The menu bar app.
        .executableTarget(name: "MedicBar", dependencies: ["MedicBarCore"]),
        .testTarget(name: "MedicBarCoreTests", dependencies: ["MedicBarCore"]),
    ]
)
