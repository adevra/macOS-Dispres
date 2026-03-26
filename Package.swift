// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Dispres",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "Dispres",
            dependencies: ["CGVirtualDisplayBridge"],
            path: "Sources/Dispres",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/Dispres/Resources/Info.plist"])
            ]
        )
    ]
)
