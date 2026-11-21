// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Mở khoá bằng khuôn mặt (port từ Glance, MIT) — xem Packages/FaceUnlockKit/NOTICE.md.
        .package(path: "Packages/FaceUnlockKit"),
        // Tự cập nhật (MIT): kiểm tra appcast, tải bản mới, xác minh chữ ký EdDSA rồi thay app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .executableTarget(name: "Notch",
                          dependencies: [.product(name: "FaceUnlockKit", package: "FaceUnlockKit"),
                                         .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Notch",
                          // Sparkle.framework nằm trong Roost.app/Contents/Frameworks.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Hook PermissionRequest của Claude Code: chuyển yêu cầu lên notch qua Unix socket.
        .executableTarget(name: "notch-hook", path: "Sources/NotchHook"),
        // Unit test cho phần logic không cần giao diện (`swift test`). Hook được thử riêng bằng scripts/test_hook.py.
        .testTarget(name: "NotchTests", dependencies: ["Notch"], path: "Tests/NotchTests"),
    ]
)
