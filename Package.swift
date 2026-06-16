// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "waik",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "waik", targets: ["WaikApp"]),
        .executable(name: "waik-helper", targets: ["WaikHelper"]),
        .executable(name: "waik-hook", targets: ["WaikHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "WaikShared",
            path: "Sources/WaikShared"
        ),
        .executableTarget(
            name: "WaikApp",
            dependencies: [
                "WaikShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/WaikApp",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "WaikHelper",
            dependencies: ["WaikShared"],
            path: "Sources/WaikHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "WaikHook",
            path: "Sources/waik-hook"
        ),
    ]
)
