// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "waik",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "waik", targets: ["WaikApp"]),
        .executable(name: "waik-helper", targets: ["WaikHelper"]),
    ],
    targets: [
        .target(
            name: "WaikShared",
            path: "Sources/WaikShared"
        ),
        .target(
            name: "WaikCore",
            path: "Sources/WaikCore"
        ),
        .target(
            name: "CProcInfo",
            path: "Sources/CProcInfo",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "WaikApp",
            dependencies: ["WaikShared", "WaikCore", "CProcInfo"],
            path: "Sources/WaikApp",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
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
        .testTarget(
            name: "WaikCoreTests",
            dependencies: ["WaikCore"],
            path: "Tests/WaikCoreTests"
        ),
    ]
)
