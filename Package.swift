// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "signal-light",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "signal-light", targets: ["SignalLightCLI"]),
        .executable(name: "signal-light-hooks", targets: ["SignalLightHooks"]),
        .library(name: "SignalLightKit", targets: ["SignalLightKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SignalLightKit"
        ),
        .executableTarget(
            name: "SignalLightCLI",
            dependencies: [
                "SignalLightKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // Info.plist is embedded directly into the binary's __TEXT,__info_plist
            // section via the linker flags below — the standard way to give a bare
            // SPM executable a CFBundleIdentifier and a Bluetooth usage string.
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/SignalLightCLI/Resources/Info.plist",
                ]),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .executableTarget(
            name: "SignalLightHooks",
            dependencies: ["SignalLightKit"]
        ),
        .testTarget(
            name: "SignalLightKitTests",
            dependencies: ["SignalLightKit"]
        ),
    ]
)
