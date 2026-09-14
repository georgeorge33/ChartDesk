// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chartdesk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Chartdesk", targets: ["Chartdesk"])
    ],
    targets: [
        .executableTarget(
            name: "Chartdesk",
            path: "Sources/Chartdesk"
        )
    ]
)
