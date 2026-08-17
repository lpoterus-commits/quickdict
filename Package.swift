// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OCRDict",
    platforms: [.macOS(.v13)],
    // 声明出来 Xcode 才认得到 scheme（xcodebuild / 分析器 / 消毒器都要靠它）
    products: [
        .executable(name: "OCRDict", targets: ["OCRDict"])
    ],
    targets: [
        .executableTarget(name: "OCRDict", path: "Sources/OCRDict")
    ]
)
