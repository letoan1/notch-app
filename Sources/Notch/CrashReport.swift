import AppKit

/// Báo crash không gửi gì tự động: lần mở sau, nếu macOS đã ghi file crash mới của Roost, hỏi người dùng có muốn
/// mở GitHub issue điền sẵn (phiên bản, macOS, lỗi, vài khung stack) không. Họ xem và sửa trước khi gửi.
enum CrashReport {
    private static let seenKey = "crash.lastSeen"
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    @MainActor static func checkOnLaunch() {
        let d = UserDefaults.standard
        let seen = d.double(forKey: seenKey)
        guard let newest = latest(in: folder, after: seen) else {
            if seen == 0 { d.set(Date().timeIntervalSince1970, forKey: seenKey) }   // lần đầu: bỏ qua crash cũ
            return
        }
        d.set(newest.date.timeIntervalSince1970, forKey: seenKey)
        guard seen > 0, let text = try? String(contentsOf: newest.url, encoding: .utf8),
              let summary = summarize(text) else { return }
        let alert = NSAlert()
        alert.messageText = L("Roost vừa bị thoát đột ngột", "Roost quit unexpectedly")
        alert.informativeText = L("Gửi báo lỗi lên GitHub giúp sửa nhanh hơn. Roost chỉ mở trang issue điền sẵn phiên bản, macOS và chỗ bị lỗi; bạn xem lại trước khi gửi.",
                                  "A report on GitHub helps get this fixed. Roost only opens a pre-filled issue with the version, macOS and where it crashed; you review it before sending.")
        alert.addButton(withTitle: L("Mở GitHub", "Open GitHub"))
        alert.addButton(withTitle: L("Bỏ qua", "Not now"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, let url = issueURL(summary) else { return }
        NSWorkspace.shared.open(url)
    }

    /// File crash mới nhất của Roost (Roost-*.ips) sửa sau mốc `after` (giây từ 1970).
    static func latest(in folder: URL, after: Double) -> (url: URL, date: Date)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("Roost-") && $0.pathExtension == "ips" }
            .compactMap { u in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (u, $0) } }
            .filter { $0.1.timeIntervalSince1970 > after }
            .max { $0.1 < $1.1 }
    }

    /// Dòng 1 là JSON tiêu đề, phần còn lại là JSON thân. Trả về đoạn markdown ngắn cho issue.
    static func summarize(_ ips: String) -> String? {
        guard let nl = ips.firstIndex(of: "\n"),
              let head = try? JSONSerialization.jsonObject(with: Data(ips[..<nl].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(ips[ips.index(after: nl)...].utf8)) as? [String: Any]
        else { return nil }
        let version = head["app_version"] as? String ?? "?"
        let build = head["build_version"] as? String ?? "?"
        let os = head["os_version"] as? String ?? (body["osVersion"] as? [String: Any])?["train"] as? String ?? "?"
        let exc = body["exception"] as? [String: Any]
        let reason = [exc?["type"] as? String, exc?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let fault = body["faultingThread"] as? Int ?? 0
        let frames = (fault < threads.count ? threads[fault]["frames"] as? [[String: Any]] : nil) ?? []
        let lines = frames.prefix(10).enumerated().map { i, f -> String in
            let img = (f["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0] : nil } ?? "?"
            let place = f["symbol"] as? String ?? "+\(f["imageOffset"] as? Int ?? 0)"
            return "\(i) \(img)  \(place)"
        }
        return """
        **Roost** \(version) (\(build)) · \(os)
        **Lỗi:** \(reason.isEmpty ? "?" : reason)

        ```
        \(lines.joined(separator: "\n"))
        ```
        """
    }

    static func issueURL(_ summary: String) -> URL? {
        var c = URLComponents(string: "https://github.com/letoan1/notch-app/issues/new")!
        let body = L("Bạn đang làm gì lúc Roost thoát? (mở tab nào, giao diện nào…)", "What were you doing when Roost quit? (which tab, which theme…)")
            + "\n\n\n---\n" + summary
        c.queryItems = [URLQueryItem(name: "title", value: "Crash: " + (summary.components(separatedBy: "\n").first ?? "")),
                        URLQueryItem(name: "labels", value: "crash"),
                        URLQueryItem(name: "body", value: body)]
        return c.url
    }
}
