// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacCharge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacCharge",
            path: "Sources/MacCharge",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
