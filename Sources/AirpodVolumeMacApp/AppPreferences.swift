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

    @Published var highVolumeWarningEnabled: Bool {
        didSet {
            defaults.set(highVolumeWarningEnabled, forKey: "highVolumeWarningEnabled")
            onHighVolumeWarningChanged?()
        }
    }

    @Published var highVolumeThreshold: Double {
        didSet {
            defaults.set(highVolumeThreshold, forKey: "highVolumeThreshold")
            onHighVolumeWarningChanged?()
        }
    }

    var onHighVolumeWarningChanged: (() -> Void)?
    var onMenuBarDisplayModeChanged: (() -> Void)?
    var onRestoreNotificationModeChanged: ((RestoreNotificationMode) -> Void)?

    private let defaults: UserDefaults
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let restoreNotificationModeKey = "restoreNotificationMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highVolumeWarningEnabled = defaults.object(forKey: "highVolumeWarningEnabled") == nil
            ? true : defaults.bool(forKey: "highVolumeWarningEnabled")
        let threshold = defaults.object(forKey: "highVolumeThreshold") == nil
            ? 60 : defaults.double(forKey: "highVolumeThreshold")
        highVolumeThreshold = threshold.isFinite ? min(max(threshold, 1), 100) : 60
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

    func requestWarningAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func deliverHighVolumeWarning(deviceName: String, percent: Int, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "AirPods 高音量提醒"
        content.body = "\(deviceName) 当前音量为 \(percent)%，已超过设定的 \(threshold)%。可适当降低音量。"
        // Silent banner: the warning itself should not add a loud sound.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "airpods-high-volume-warning", content: content, trigger: nil
        ))
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

/// Tracks threshold crossings independently of UI rendering frequency.
struct HighVolumeWarningGate {
    private var warnedDevice: String?

    mutating func shouldWarn(deviceUID: String?, volume: Float?, enabled: Bool, threshold: Double) -> Bool {
        guard enabled, let uid = deviceUID, let volume, volume.isFinite else {
            warnedDevice = nil
            return false
        }
        guard Double(volume) * 100 > threshold + 0.0001 else {
            warnedDevice = nil
            return false
        }
        guard warnedDevice != uid else { return false }
        warnedDevice = uid
        return true
    }
}
