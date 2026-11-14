// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PVEHub",
    platforms: [.iOS(.v17)],
    products: [
        // xtool : une seule bibliothèque, l'app elle-même
        .library(name: "PVEHub", targets: ["PVEHub"]),
    ],
    targets: [
        .target(name: "PVEHub", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
