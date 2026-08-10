// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentBar", targets: ["AgentBar"]),
    ],
    targets: [
        .target(
            name: "TouchBarPrivateBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "AgentBar",
            dependencies: ["TouchBarPrivateBridge"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
