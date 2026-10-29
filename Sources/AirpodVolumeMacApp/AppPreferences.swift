import Combine
import Foundation
import UserNotifications

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndPercentage
    case compactText
    case deviceName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .iconAndPercentage: return "图标和百分比"
        case .compactText: return "AirPods 和百分比"
        case .deviceName: return "设备名称和百分比"
        }
    }
}

enum RestoreNotificationMode: String, CaseIterable, Identifiable {
    case off
    case failuresOnly
    case allResults

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .failuresOnly: return "仅失败时通知"
        case .allResults: return "所有恢复结果"
        }
    }
}

final class AppPreferences: ObservableObject {
    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            defaults.set(menuBarDisplayMode.rawValue, forKey: menuBarDisplayModeKey)
            onMenuBarDisplayModeChanged?()
        }
    }

    @Published var restoreNotificationMode: RestoreNotificationMode {
        didSet {
            defaults.set(restoreNotificationMode.rawValue, forKey: restoreNotificationModeKey)
            onRestoreNotificationModeChanged?(restoreNotificationMode)
        }
    }

    var onMenuBarDisplayModeChanged: (() -> Void)?
    var onRestoreNotificationModeChanged: ((RestoreNotificationMode) -> Void)?

    private let defaults: UserDefaults
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let restoreNotificationModeKey = "restoreNotificationMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarDisplayMode = MenuBarDisplayMode(
            rawValue: defaults.string(forKey: menuBarDisplayModeKey) ?? ""
        ) ?? .compactText
        restoreNotificationMode = RestoreNotificationMode(
            rawValue: defaults.string(forKey: restoreNotificationModeKey) ?? ""
        ) ?? .off
    }
}

final class RestoreNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func modeChanged(_ mode: RestoreNotificationMode) {
        guard mode != .off else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliver(_ event: RestoreNotificationEvent, mode: RestoreNotificationMode) {
        guard mode == .allResults || (mode == .failuresOnly && !event.succeeded) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.succeeded ? "AirPods 音量已恢复" : "AirPods 音量恢复失败"
        if let volume = event.volume {
            let percent = Int((min(max(volume, 0), 1) * 100).rounded())
            content.body = event.succeeded
                ? "\(event.deviceName) 已恢复至 \(percent)%."
                : "\(event.deviceName) 仍为 \(percent)%。请打开 AirPods 音量重试。"
        } else {
            content.body = "无法验证音量：\(event.deviceName). 请打开 AirPods 音量重试。"
        }
        content.sound = event.succeeded ? nil : .default

        let request = UNNotificationRequest(
            identifier: "airpods-volume-restore-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
