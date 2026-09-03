// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "M10Kit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "M10Kit", targets: ["M10Kit"]),
    ],
    targets: [
        .target(name: "M10Kit"),
        .testTarget(name: "M10KitTests", dependencies: ["M10Kit"],
                    resources: [.copy("Fixtures")]),
    ]
)
