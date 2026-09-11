// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "kilde",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // コアライブラリ: CLI / GUI で共用する録画エンジン (DESIGN.md §4)
        .target(
            name: "KildeCore",
            path: "Sources/KildeCore"
        ),
        .executableTarget(
            name: "kilde",
            dependencies: [
                .target(name: "KildeCore"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/kilde"
        ),
    ]
)
