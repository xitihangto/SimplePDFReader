// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimplePDFReader",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SimplePDFReader", targets: ["SimplePDFReader"])
    ],
    targets: [
        .executableTarget(
            name: "SimplePDFReader",
            path: "Sources/SimplePDFReader"
        )
    ]
)
