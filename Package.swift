// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notch", path: "Sources/Notch"),
        // Hook PermissionRequest của Claude Code: chuyển yêu cầu lên notch qua Unix socket.
        .executableTarget(name: "notch-hook", path: "Sources/NotchHook"),
    ]
)
