// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StrideKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StrideKit", targets: ["StrideKit"])
    ],
    // Exact versions. ../Package.resolved pins these and what they depend on.
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.4"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
        .package(url: "https://github.com/davidstump/SwiftPhoenixClient", exact: "5.3.5")
    ],
    targets: [
        .target(
            name: "StrideKit",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "SwiftPhoenixClient", package: "SwiftPhoenixClient")
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "StrideKitTests",
            dependencies: [
                "StrideKit",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "SwiftPhoenixClient", package: "SwiftPhoenixClient")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
