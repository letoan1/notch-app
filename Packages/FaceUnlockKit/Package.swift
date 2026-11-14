// swift-tools-version:5.9
//
// FaceUnlockKit — face-unlock core adapted from Glance (MIT, © Jonathan Zhou).
// Vendored into Notch (Packages/FaceUnlockKit); smoke target and _upstream/ dropped.
// Builds with Command Line Tools only (`swift build`); no Xcode, no SwiftUI/Observation macros.
import PackageDescription

let package = Package(
    name: "FaceUnlockKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FaceUnlockKit", targets: ["FaceUnlockKit"]),
    ],
    targets: [
        .target(
            name: "FaceUnlockKit",
            path: "Sources/FaceUnlockKit",
            // ArcFace.mlpackage stored WITHOUT its extension: SwiftPM's build system recognizes `.mlpackage` (even under
            // `.copy`) and tries to run `coremlc`, which Command Line Tools don't have. `ArcFaceModelStore` restores the
            // extension in a private staging folder and compiles at runtime with `MLModel.compileModel(at:)`.
            resources: [.copy("Resources/ArcFaceModel")],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreImage"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
