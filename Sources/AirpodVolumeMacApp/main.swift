import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
        reopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showWindowNotification,
            object: String(getuid()), queue: .main
        ) { [weak self] _ in self?.statusBarController?.showDeviceManager() }
        if CommandLine.arguments.contains("--show-settings") {
            statusBarController?.showDeviceManager()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
        if let reopenObserver {
            DistributedNotificationCenter.default().removeObserver(reopenObserver)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusBarController?.showDeviceManager()
        return true
    }
}

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let titleLabel = NSTextField(labelWithString: "正在启动…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "--")
    private let loginItems = LoginItemController()
    private let controller = VolumeMemoryController()
    private let preferences = AppPreferences()
    private let notificationManager = RestoreNotificationManager()
    private let stallMonitor = PlaybackStallMonitor()
    private lazy var deviceManagerViewModel = DeviceManagerViewModel(
        controller: controller,
        preferences: preferences,
        loginItems: loginItems
    )
    private lazy var deviceManagerWindowController = DeviceManagerWindowController(
        viewModel: deviceManagerViewModel
    )
    private lazy var settingsItem = makeMenuItem(
        title: "设置…",
        action: #selector(showDeviceManager),
        keyEquivalent: ","
    )
    private var isRenderingStatus = false
    private var wakeObserver: NSObjectProtocol?
    private var highVolumeWarningGate = HighVolumeWarningGate()
    private var lastStatus: VolumeMemoryStatus?

    override init() {
        super.init()
        configureStatusItem()
        configureMenu()
        loginItems.prepareLegacyMigration()

        controller.onStatusChanged = { [weak self] status in
            DispatchQueue.main.async {
                self?.render(status)
            }
        }
        controller.onDataChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.deviceManagerViewModel.receive(snapshot)
            }
        }
        controller.onRestoreNotification = { [weak self] event in
            guard let self else { return }
            // The connection notification already reports this result.
            if event.isConnectionRestore && self.preferences.connectionNotificationEnabled { return }
            self.notificationManager.deliver(event, mode: self.preferences.restoreNotificationMode)
        }
        controller.onConnectionNotification = { [weak self] event in
            guard let self, self.preferences.connectionNotificationEnabled else { return }
            self.notificationManager.deliverConnection(event, muted: self.outputIsMuted)
        }
        preferences.onMenuBarDisplayModeChanged = { [weak self] in
            guard let self, let status = self.lastStatus else { return }
            self.renderMenuBar(status)
        }
        preferences.onRestoreNotificationModeChanged = { [weak self] mode in
            self?.notificationManager.modeChanged(mode)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller.handleSystemWake()
        }
        preferences.onHighVolumeWarningChanged = { [weak self] in
            guard let self else { return }
            if self.preferences.highVolumeWarningEnabled {
                self.notificationManager.requestAuthorization()
            }
            self.highVolumeWarningGate = HighVolumeWarningGate()
            if let status = self.lastStatus { self.checkHighVolume(status) }
        }
        preferences.onConnectionNotificationChanged = { [weak self] in
            guard let self, self.preferences.connectionNotificationEnabled else { return }
            self.notificationManager.requestAuthorization()
        }
        if preferences.anyNotificationEnabled {
            notificationManager.requestAuthorization()
        }
        stallMonitor.isEnabled = { [weak self] in self?.preferences.fixSilentSwitchEnabled ?? false }
        preferences.onFixSilentSwitchChanged = { [weak self] in
            guard let self else { return }
            self.updateStallMonitor()
            if self.preferences.fixSilentSwitchEnabled && !AccessibilityAccess.isTrusted {
                AccessibilityAccess.request()
            }
            self.deviceManagerViewModel.refreshRuntimeState()
        }
        updateStallMonitor()
        controller.start()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func stop() {
        stallMonitor.stop()
        controller.stop()
    }

    /// The iPhone-Mac switch fix only listens to the device while it is turned on.
    private func updateStallMonitor() {
        if preferences.fixSilentSwitchEnabled {
            stallMonitor.start()
        } else {
            stallMonitor.stop()
        }
    }

    private func configureStatusItem() {
        statusItem.button?.title = "AirPods Vol"
        statusItem.button?.toolTip = "AirPods 音量记忆"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(makeHeaderItem())
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refresh()
        deviceManagerViewModel.refreshRuntimeState()
    }

    /// Device name, what happens to its volume, and the volume slider in one block.
    private func makeHeaderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 74))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        volumeValueLabel.alignment = .right
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        [titleLabel, detailLabel].forEach { $0.lineBreakMode = .byTruncatingTail }

        [titleLabel, detailLabel, volumeSlider, volumeValueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            volumeSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            volumeSlider.trailingAnchor.constraint(equalTo: volumeValueLabel.leadingAnchor, constant: -8),
            volumeSlider.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),

            volumeValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeValueLabel.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),
            volumeValueLabel.widthAnchor.constraint(equalToConstant: 42)
        ])

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private var outputIsMuted: Bool {
        guard let device = try? AudioHardware.defaultOutputDevice() else { return false }
        return AudioHardware.outputMuted(for: device.id)
    }

    private func render(_ status: VolumeMemoryStatus) {
        isRenderingStatus = true
        defer { isRenderingStatus = false }
        lastStatus = status

        checkHighVolume(status)
        renderMenuBar(status)
        let muted = outputIsMuted
        let lines = MenuStatusText.lines(for: status, muted: muted)
        titleLabel.stringValue = lines.title
        detailLabel.stringValue = lines.detail

        if let currentVolume = status.currentVolume {
            let percent = Int((min(max(currentVolume, 0), 1) * 100).rounded())
            volumeSlider.doubleValue = Double(percent)
            volumeValueLabel.stringValue = muted ? "静音" : "\(percent)%"
        } else {
            volumeSlider.doubleValue = 0
            volumeValueLabel.stringValue = "--"
        }

        volumeSlider.isEnabled = status.canAdjustVolume
        deviceManagerViewModel.refreshRuntimeState()
    }

    private func checkHighVolume(_ status: VolumeMemoryStatus) {
        // Reconnect volume is often briefly high before the restore lands. Leave the
        // gate untouched; the settled status that follows is checked normally.
        guard !status.isSettling else { return }
        let uid = status.canAdjustVolume ? controller.dataSnapshot().currentDeviceUID : nil
        if highVolumeWarningGate.shouldWarn(
            deviceUID: uid,
            volume: status.currentVolume,
            enabled: preferences.highVolumeWarningEnabled && !outputIsMuted,
            threshold: preferences.highVolumeThreshold
        ), let volume = status.currentVolume {
            notificationManager.deliverHighVolumeWarning(
                deviceName: status.currentDeviceName ?? "AirPods",
                volume: volume,
                threshold: Int(preferences.highVolumeThreshold.rounded())
            )
        }
    }

    private func renderMenuBar(_ status: VolumeMemoryStatus) {
        guard let button = statusItem.button else { return }
        let muted = outputIsMuted
        let percent = status.currentVolume.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        let icon = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPods 音量")
        icon?.isTemplate = true

        switch preferences.menuBarDisplayMode {
        case .iconOnly:
            button.image = icon
            button.title = ""
        case .iconAndPercentage:
            button.image = icon
            button.title = muted ? " 静音" : (percent.map { " \($0)%" } ?? "")
        case .compactText:
            button.image = nil
            button.title = muted && status.canAdjustVolume ? "AirPods 静音" : status.menuBarTitle
        case .deviceName:
            button.image = nil
            if let name = status.currentDeviceName, let percent {
                button.title = muted ? "\(name) 静音" : "\(name) \(percent)%"
            } else {
                button.title = "AirPods Vol"
            }
        }
        button.toolTip = muted ? "当前已静音" : status.primaryText
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc func showDeviceManager() {
        deviceManagerWindowController.show()
    }

    @objc private func volumeSliderChanged() {
        guard !isRenderingStatus else {
            return
        }

        // Whole percents: fine enough to set any level, and what the label shows.
        let percent = volumeSlider.doubleValue.rounded()
        volumeSlider.doubleValue = percent
        volumeValueLabel.stringValue = "\(Int(percent))%"
        controller.setCurrentAirPodsVolume(Float(percent / 100))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// Installer commands run before AppKit and the process lock. They never create
// a second menu-bar item and preserve the original bundle identifier/storage.
if CommandLine.arguments.contains("--login-item-status") {
    print(SystemLoginStartupBackend().snapshot().nativeStatus.rawValue)
    exit(0)
}
if CommandLine.arguments.contains("--prepare-login-migration") {
    let startup = LoginItemController()
    startup.prepareLegacyMigration()
    if let error = startup.lastError { fputs("\(error)\n", stderr) }
    print(startup.state.nativeStatus.rawValue)
    exit(0)
}

let instance: SingleInstance
do {
    instance = try SingleInstance(lockURL: SingleInstance.defaultLockURL)
    if try !instance.acquire() {
        // The first process may still be bringing up AppKit during simultaneous
        // launches. Retry the wake-up briefly without creating another UI.
        for _ in 0..<3 {
            DistributedNotificationCenter.default().postNotificationName(
                SingleInstance.showWindowNotification, object: String(getuid()),
                userInfo: nil, deliverImmediately: true
            )
            Thread.sleep(forTimeInterval: 0.2)
        }
        exit(0)
    }
} catch {
    fputs("无法取得应用进程锁：\(error.localizedDescription)\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instance) { app.run() }
