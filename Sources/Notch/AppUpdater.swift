import Combine
import Foundation
import Sparkle

/// Tự cập nhật bằng Sparkle. Appcast nằm trên GitHub Releases (SUFeedURL trong Info.plist); mỗi bản .dmg
/// được ký EdDSA bằng khoá riêng trong login keychain của máy phát hành (SUPublicEDKey để xác minh).
/// Chữ ký sai hoặc thiếu thì Sparkle từ chối cài. Mặc định kiểm tra mỗi ngày một lần, không gửi gì ngoài
/// yêu cầu tải appcast (Sparkle không bật thu thập thông tin hệ thống).
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var cancellables = Set<AnyCancellable>()

    /// Sparkle cho phép bấm "Kiểm tra" (không có lượt kiểm tra nào đang chạy).
    @Published private(set) var canCheck = false
    @Published var autoCheck: Bool {
        didSet { if controller.updater.automaticallyChecksForUpdates != autoCheck { controller.updater.automaticallyChecksForUpdates = autoCheck } }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    private init() {
        autoCheck = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheck = value } }
            .store(in: &cancellables)
    }

    func checkNow() { controller.checkForUpdates(nil) }
}
