// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Dewy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Dewy", targets: ["DewyApp"])],
    targets: [.executableTarget(name: "DewyApp", path: "Sources/DewyApp")]
)
