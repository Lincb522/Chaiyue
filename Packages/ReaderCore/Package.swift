// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReaderCore",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ReaderModels", targets: ["ReaderModels"]),
        .library(name: "RuleEngine", targets: ["RuleEngine"]),
        .library(name: "ReaderServices", targets: ["ReaderServices"]),
        .library(name: "ReaderKit", targets: ["ReaderKit"]),
        .library(name: "ReaderPlatform", targets: ["ReaderPlatform"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.3"),
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "6.1.0"),
        .package(url: "https://github.com/KittyMac/Sextant.git", from: "0.4.41"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .target(
            name: "ReaderModels",
            path: "Sources/ReaderModels"
        ),
        .target(
            name: "RuleEngine",
            dependencies: [
                "ReaderModels",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "Kanna", package: "Kanna"),
                .product(name: "Sextant", package: "Sextant"),
            ],
            path: "Sources/RuleEngine"
        ),
        // App 层服务：书源仓库、导入、书架、章节缓存、替换净化、多源搜索、本地书、备份
        .target(
            name: "ReaderServices",
            dependencies: [
                "ReaderModels",
                "RuleEngine",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/ReaderServices"
        ),
        // 排版与分页
        .target(
            name: "ReaderKit",
            dependencies: ["ReaderModels"],
            path: "Sources/ReaderKit"
        ),
        // 平台能力：WebKit 后台渲染、Cookie 同步、书源交互（浏览器、验证码）的界面协议
        .target(
            name: "ReaderPlatform",
            dependencies: ["RuleEngine", "ReaderModels"],
            path: "Sources/ReaderPlatform"
        ),
        // 命令行探针：在 macOS 上用真实书源跑完整流程，只输出结构信息
        .executableTarget(
            name: "SourceProbe",
            dependencies: ["RuleEngine", "ReaderModels"],
            path: "Sources/SourceProbe"
        ),
        .testTarget(
            name: "ReaderModelsTests",
            dependencies: ["ReaderModels"],
            path: "Tests/ReaderModelsTests"
        ),
        .testTarget(
            name: "RuleEngineTests",
            dependencies: ["RuleEngine", "ReaderModels"],
            path: "Tests/RuleEngineTests"
        ),
        .testTarget(
            name: "ReaderServicesTests",
            dependencies: [
                "ReaderServices",
                "RuleEngine",
                "ReaderModels",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Tests/ReaderServicesTests"
        ),
        .testTarget(
            name: "ReaderKitTests",
            dependencies: ["ReaderKit", "ReaderModels"],
            path: "Tests/ReaderKitTests"
        ),
        .testTarget(
            name: "ReaderPlatformTests",
            dependencies: ["ReaderPlatform", "RuleEngine"],
            path: "Tests/ReaderPlatformTests"
        ),
    ]
)
