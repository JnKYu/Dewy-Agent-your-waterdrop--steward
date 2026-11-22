// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Dewy",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Dewy", targets: ["DewyApp"])],
    dependencies: [
        // 第一处：声明要用这个包
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "DewyApp",
            dependencies: [
                // 第二处：告诉你的 target 要使用它
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/DewyApp"
        )
    ]
)
