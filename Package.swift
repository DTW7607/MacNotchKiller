// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FullScreenTools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FullScreenTools", targets: ["FullScreenTools"])
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "FullScreenTools",
            dependencies: ["VirtualDisplayBridge"]
        )
    ],
    swiftLanguageModes: [.v5]
)
