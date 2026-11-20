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
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0"),
        // Already resolved for MarkdownUI; used directly to render reports as one text.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "PeachyPet",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
            path: "Sources",
            exclude: ["PeachyPet.entitlements", "Resources/AppIcon.icns"],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/Images"),
                .copy("Resources/Defaults"),
                .copy("Resources/Extensions"),
                .process("Resources/en.lproj"),
                .process("Resources/zh.lproj")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "PeachyPetTests",
            dependencies: ["PeachyPet"],
            path: "Tests"
        )
    ]
)
