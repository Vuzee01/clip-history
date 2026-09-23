// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClipHistory", targets: ["ClipHistory"])],
    targets: [
        .executableTarget(name: "ClipHistory")
    ],
    swiftLanguageModes: [.v5]
)
