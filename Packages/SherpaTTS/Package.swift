// swift-tools-version: 5.9
// 本地神经语音：sherpa-onnx 官方 iOS 静态框架 + 精简封装。框架由 App/Tools/fetch_kokoro.sh 下载
import PackageDescription

let package = Package(
    name: "SherpaTTS",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SherpaTTS", targets: ["SherpaTTS"]),
    ],
    targets: [
        .binaryTarget(name: "SherpaOnnxC", path: "Frameworks/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework"),
        .target(
            name: "SherpaTTS",
            dependencies: ["SherpaOnnxC", "onnxruntime"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
