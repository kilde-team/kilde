// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "kilde",
    platforms: [.macOS(.v14)],
    targets: [
        // M0 スパイク用の実行ファイル。M1 で KildeCore / kilde CLI に再構成する。
        .executableTarget(
            name: "spike",
            path: "Sources/Spike"
        ),
    ]
)
