// swift-tools-version: 6.0
// PhazeSwiftUI — phaze-native's SwiftUI WebView shell, imported as `Phaze`, and `PhazeAuth`,
// the authenticator half of phaze-auth for a shell that signs in with a machine key.
import PackageDescription

let package = Package(
    name: "PhazeSwiftUI",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Phaze", targets: ["Phaze"]),
        .library(name: "PhazeAuth", targets: ["PhazeAuth"]),
    ],
    targets: [
        .target(name: "Phaze"),
        .target(name: "PhazeAuth"),
    ]
)
