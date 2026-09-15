// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chartdesk",
    platforms: [
        // Raised for 1.0. `.v26` is not a symbol in tools 5.9, so the version is spelled out.
        .macOS("26.0")
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
