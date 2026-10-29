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

    @Published var connectionNotificationEnabled: Bool {
        didSet {
            defaults.set(connectionNotificationEnabled, forKey: connectionNotificationEnabledKey)
            onConnectionNotificationChanged?()
        }
    }

    @Published var fixSilentSwitchEnabled: Bool {
        didSet {
            defaults.set(fixSilentSwitchEnabled, forKey: fixSilentSwitchEnabledKey)
            onFixSilentSwitchChanged?()
        }
    }

    var onHighVolumeWarningChanged: (() -> Void)?
    var onFixSilentSwitchChanged: (() -> Void)?
    var onConnectionNotificationChanged: (() -> Void)?
    var onMenuBarDisplayModeChanged: (() -> Void)?
    var onRestoreNotificationModeChanged: ((RestoreNotificationMode) -> Void)?

    private let defaults: UserDefaults
    private let menuBarDisplayModeKey = "menuBarDisplayMode"
    private let restoreNotificationModeKey = "restoreNotificationMode"
    private let connectionNotificationEnabledKey = "connectionNotificationEnabled"
    private let fixSilentSwitchEnabledKey = "fixSilentSwitchEnabled"

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
        connectionNotificationEnabled = defaults.object(forKey: connectionNotificationEnabledKey) == nil
            ? true : defaults.bool(forKey: connectionNotificationEnabledKey)
        // Opt-in: it presses media keys, which not every setup needs.
        fixSilentSwitchEnabled = defaults.bool(forKey: fixSilentSwitchEnabledKey)
    }

    var anyNotificationEnabled: Bool {
        highVolumeWarningEnabled || connectionNotificationEnabled || restoreNotificationMode != .off
    }
}

final class RestoreNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Always ask for every option at once: macOS shows the prompt only the first
    /// time, so options requested later are never granted.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func deliverConnection(_ event: ConnectionNotificationEvent, muted: Bool) {
        let text = NotificationText.connection(event, muted: muted)
        // One banner per device: a quick reconnect replaces the previous one.
        add(identifier: "airpods-connected-\(event.deviceUID)", text: text,
            volume: event.volume, muted: muted, sound: event.outcome == .failed)
    }

    func deliverHighVolumeWarning(deviceName: String, volume: Float, threshold: Int) {
        // Silent banner: the warning itself should not add a loud sound.
        add(identifier: "airpods-high-volume-warning",
            text: NotificationText.highVolume(deviceName: deviceName, volume: volume, threshold: threshold),
            volume: volume, muted: false, sound: false)
    }

    func modeChanged(_ mode: RestoreNotificationMode) {
        guard mode != .off else {
            return
        }
        requestAuthorization()
    }

    func deliver(_ event: RestoreNotificationEvent, mode: RestoreNotificationMode) {
        guard mode == .allResults || (mode == .failuresOnly && !event.succeeded) else {
            return
        }
        add(identifier: "airpods-volume-restore-\(UUID().uuidString)", text: NotificationText.restore(event),
            volume: event.volume, muted: false, sound: !event.succeeded)
    }

    private func add(identifier: String, text: NotificationText, volume: Float?, muted: Bool, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = sound ? .default : nil
        if let attachment = gaugeAttachment(volume: volume, muted: muted) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        ))
    }

    /// The volume ring shown on the right of the banner. The system moves the file
    /// into its own store, so each notification gets a fresh temporary copy.
    private func gaugeAttachment(volume: Float?, muted: Bool) -> UNNotificationAttachment? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airpods-volume-\(UUID().uuidString).png")
        guard let image = VolumeGauge.image(size: 256, style: VolumeGauge.notificationStyle(volume: volume, muted: muted)),
              VolumeGauge.writePNG(image, to: url) else {
            return nil
        }
        return try? UNNotificationAttachment(identifier: "gauge", url: url)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Notification wording: the volume is the headline, the device and what
/// happened go on the second line.
struct NotificationText: Equatable {
    let title: String
    let body: String

    static func connection(_ event: ConnectionNotificationEvent, muted: Bool) -> NotificationText {
        let status: String
        switch event.outcome {
        case .restored: status = "已恢复记忆音量"
        case .failed:
            status = event.rememberedVolume.map { "未能恢复到 \(percent($0))，可在菜单中重试" }
                ?? "恢复未生效，可在菜单中重试"
        case .paused: status = "自动恢复已暂停"
        case .automaticRestoreOff: status = "未自动恢复"
        case .noRememberedVolume: status = "已记为初始音量"
        case .pending, .interrupted: status = "已连接"
        }
        return NotificationText(title: headline(volume: event.volume, muted: muted), body: "\(event.deviceName) · \(status)")
    }

    static func restore(_ event: RestoreNotificationEvent) -> NotificationText {
        let status: String
        if event.succeeded {
            status = "已恢复记忆音量"
        } else {
            status = event.volume == nil ? "无法验证音量，可在菜单中重试" : "恢复未生效，可在菜单中重试"
        }
        return NotificationText(title: headline(volume: event.volume, muted: false), body: "\(event.deviceName) · \(status)")
    }

    static func highVolume(deviceName: String, volume: Float, threshold: Int) -> NotificationText {
        NotificationText(
            title: headline(volume: volume, muted: false),
            body: "\(deviceName) · 已超过提醒阈值 \(threshold)%，可适当调低"
        )
    }

    private static func headline(volume: Float?, muted: Bool) -> String {
        guard let volume else { return "AirPods 已连接" }
        return muted ? "AirPods 已静音 · \(percent(volume))" : "AirPods 音量 \(percent(volume))"
    }

    private static func percent(_ volume: Float) -> String {
        "\(Int((min(max(volume, 0), 1) * 100).rounded()))%"
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
