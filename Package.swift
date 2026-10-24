// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wifiscan",
    platforms: [.macOS(.v15)],
    targets: [
        // Core library: scanning + scoring + analisi. Senza UI.
        .target(
            name: "WifiScanCore",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),

        // CLI esistente.
        .executableTarget(
            name: "wifiscan",
            dependencies: ["WifiScanCore"]
        ),

        // App SwiftUI con Liquid Glass.
        .executableTarget(
            name: "WifiScannerApp",
            dependencies: ["WifiScanCore"]
        ),

        .testTarget(
            name: "WifiScanCoreTests",
            dependencies: ["WifiScanCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
