// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Mở khoá bằng khuôn mặt (port từ Glance, MIT) — xem Packages/FaceUnlockKit/NOTICE.md.
        .package(path: "Packages/FaceUnlockKit"),
    ],
    targets: [
        .executableTarget(name: "Notch",
                          dependencies: [.product(name: "FaceUnlockKit", package: "FaceUnlockKit")],
                          path: "Sources/Notch"),
        // Hook PermissionRequest của Claude Code: chuyển yêu cầu lên notch qua Unix socket.
        .executableTarget(name: "notch-hook", path: "Sources/NotchHook"),
    ]
)
