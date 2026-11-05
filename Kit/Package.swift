// swift-tools-version: 6.2
import PackageDescription

// The app's code. A package rather than sources in the Xcode target so the unit tests link the SDK and its
// TiantingIMTesting fakes exactly once (a hosted Xcode test bundle would get a second static copy of the SDK).
let package = Package(
    name: "TiantingAppKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "TiantingAppKit", targets: ["TiantingAppKit"])
    ],
    dependencies: [
        .package(path: "../../tianting-sdk-swift")
    ],
    targets: [
        .target(
            name: "TiantingAppKit",
            dependencies: [.product(name: "TiantingIM", package: "tianting-sdk-swift")],
            // Isolation is written out on each class, not set with .defaultIsolation(MainActor.self): that gives
            // classes an isolated deinit, whose back-deployment shim crashes on iOS 18.5 (seen in the unit tests).
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TiantingAppKitTests",
            dependencies: [
                "TiantingAppKit",
                .product(name: "TiantingIM", package: "tianting-sdk-swift"),
                .product(name: "TiantingIMTesting", package: "tianting-sdk-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
