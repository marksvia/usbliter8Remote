// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "usbliter8-remote",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "usbliter8 remote", targets: ["usbliter8Remote"])
    ],
    targets: [
        .executableTarget(
            name: "usbliter8Remote",
            exclude: ["Resources"],
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
