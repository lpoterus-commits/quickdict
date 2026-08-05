// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OCRDict",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "OCRDict", path: "Sources/OCRDict")
    ]
)
