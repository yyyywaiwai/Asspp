// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StoreKBSync",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "StoreKBSync", targets: ["StoreKBSync"])],
    targets: [
        .binaryTarget(name: "StoreKBSyncNative", path: "Frameworks/StoreKBSyncNative.xcframework"),
        .binaryTarget(name: "UnicornTCI", path: "Frameworks/UnicornTCI.xcframework"),
        .target(name: "CStoreKBSync", dependencies: ["UnicornTCI"]),
        .target(
            name: "StoreKBSync", dependencies: ["StoreKBSyncNative", "CStoreKBSync"],
            resources: [.copy("Resources/Assets"), .copy("Resources/Notices")],
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("Security"), .linkedLibrary("resolv")]
        ),
        .testTarget(name: "StoreKBSyncTests", dependencies: ["StoreKBSync"]),
    ]
)
