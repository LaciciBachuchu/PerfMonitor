// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PerfMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CSensors",
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "PerfMonitor",
            dependencies: ["CSensors"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Probe",
            dependencies: ["CSensors"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
