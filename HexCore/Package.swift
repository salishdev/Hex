// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HexCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HexCore", targets: ["HexCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Clipy/Sauce", branch: "master"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.9.1"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.8.0"),
    ],
    targets: [
	    .target(
	        name: "HexCore",
	        dependencies: [
	            "Sauce",
	            .product(name: "Dependencies", package: "swift-dependencies"),
	            .product(name: "DependenciesMacros", package: "swift-dependencies"),
	            .product(name: "Logging", package: "swift-log"),
            // Storage uses isTesting to isolate hosted tests from real user data.
            .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
	        ],
	        path: "Sources/HexCore",
	        linkerSettings: [
	            .linkedFramework("IOKit")
	        ]
	    ),
        .testTarget(
            name: "HexCoreTests",
            dependencies: [
                "HexCore",
                // Use the public Testing bridge instead of runtime layout assumptions.
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
            ],
            path: "Tests/HexCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
