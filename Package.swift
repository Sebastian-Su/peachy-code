// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PeachyPet",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "PeachyPet",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources",
            exclude: ["PeachyPet.entitlements"],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Images"),
                .copy("Resources/Defaults"),
                .copy("Resources/Extensions"),
                .process("Resources/en.lproj"),
                .process("Resources/zh.lproj")
            ]
        ),
        .testTarget(
            name: "PeachyPetTests",
            dependencies: ["PeachyPet"],
            path: "Tests"
        )
    ]
)
