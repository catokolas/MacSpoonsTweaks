// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacSpoonsTweaks",
    platforms: [
        // macOS 14 (Sonoma) gives us NavigationSplitView, modern SwiftUI APIs.
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MacSpoonsTweaks", targets: ["MacSpoonsTweaks"]),
        .library(name: "MacSpoonsTweaksKit", targets: ["MacSpoonsTweaksKit"]),
    ],
    targets: [
        // Pure-data / network layer. Has no SwiftUI dependency so the
        // whole layer is exercisable from `swift test` on the CLI.
        .target(
            name: "MacSpoonsTweaksKit",
            path: "Sources/MacSpoonsTweaksKit"
        ),
        // SwiftUI @main app. Depends on Kit. Open Package.swift in Xcode
        // to build/run the UI; `swift run MacSpoonsTweaks` works but Mac-
        // app affordances (menu bar, dock) come up cleaner from Xcode.
        .executableTarget(
            name: "MacSpoonsTweaks",
            dependencies: ["MacSpoonsTweaksKit"],
            path: "Sources/MacSpoonsTweaks"
        ),
        .testTarget(
            name: "MacSpoonsTweaksKitTests",
            dependencies: ["MacSpoonsTweaksKit"],
            path: "Tests/MacSpoonsTweaksKitTests",
            resources: [
                // Pinned snapshot of HS_SpoonsContrib/spoons.json used as
                // a fixture so decode tests are stable regardless of
                // network state or upstream changes.
                .copy("Fixtures"),
            ]
        ),
    ]
)
