// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StrideKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StrideKit", targets: ["StrideKit"])
    ],
    targets: [
        .target(name: "StrideKit"),
        .testTarget(name: "StrideKitTests", dependencies: ["StrideKit"])
    ],
    swiftLanguageModes: [.v6]
)
