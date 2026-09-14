// swift-tools-version: 6.0
// PhazeSwiftUI — phaze-native's SwiftUI WebView shell, imported as `Phaze`.
import PackageDescription

let package = Package(
    name: "PhazeSwiftUI",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Phaze", targets: ["Phaze"]),
    ],
    targets: [
        .target(name: "Phaze"),
    ]
)
