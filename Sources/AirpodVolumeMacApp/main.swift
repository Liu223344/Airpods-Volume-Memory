import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.stop()
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
    private let statusMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "正在监听声音设备。", action: nil, keyEquivalent: "")
    private let volumeSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let volumeValueLabel = NSTextField(labelWithString: "--")
    private lazy var restoreNowItem = makeMenuItem(
        title: "恢复记忆音量",
        action: #selector(restoreRememberedVolumeNow),
        keyEquivalent: "r"
    )
    private lazy var saveNowItem = makeMenuItem(
        title: "保存当前音量",
        action: #selector(saveCurrentVolumeNow),
        keyEquivalent: "s"
    )
    private lazy var automaticRestoreItem = makeMenuItem(
        title: "自动恢复音量",
        action: #selector(toggleAutomaticRestore)
    )
    private lazy var launchAtLoginItem = makeMenuItem(
        title: "登录时启动",
        action: #selector(toggleLaunchAtLogin)
    )
    private let controller = VolumeMemoryController()
    private let preferences = AppPreferences()
    private let notificationManager = RestoreNotificationManager()
    private lazy var deviceManagerViewModel = DeviceManagerViewModel(
        controller: controller,
        preferences: preferences
    )
    private lazy var deviceManagerWindowController = DeviceManagerWindowController(
        viewModel: deviceManagerViewModel
    )
    private lazy var manageDevicesItem = makeMenuItem(
        title: "管理 AirPods…",
        action: #selector(showDeviceManager),
        keyEquivalent: ","
    )
    private lazy var resumeRestoresItem = makeMenuItem(
        title: "恢复自动调节",
        action: #selector(resumeRestores)
    )
    private lazy var pauseRestoresItem = makePauseMenuItem()
    private var isRenderingStatus = false
    private var wakeObserver: NSObjectProtocol?
    private var highVolumeWarningGate = HighVolumeWarningGate()
    private var lastStatus: VolumeMemoryStatus?

    override init() {
        super.init()
        configureStatusItem()
        configureMenu()

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
            self.notificationManager.deliver(event, mode: self.preferences.restoreNotificationMode)
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
                self.notificationManager.requestWarningAuthorization()
            }
            self.highVolumeWarningGate = HighVolumeWarningGate()
            if let status = self.lastStatus { self.checkHighVolume(status) }
        }
        if preferences.highVolumeWarningEnabled {
            notificationManager.requestWarningAuthorization()
        }
        controller.start()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func stop() {
        controller.stop()
    }

    private func configureStatusItem() {
        statusItem.button?.title = "AirPods Vol"
        statusItem.button?.toolTip = "AirPods 音量记忆"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self
        statusMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeSliderChanged)
        volumeSlider.isContinuous = true
        volumeSlider.numberOfTickMarks = 17
        volumeSlider.allowsTickMarkValuesOnly = true

        let quitItem = NSMenuItem(
            title: "退出 AirPods 音量",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(detailMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeVolumeSliderItem())
        menu.addItem(.separator())
        menu.addItem(restoreNowItem)
        menu.addItem(saveNowItem)
        menu.addItem(.separator())
        menu.addItem(pauseRestoresItem)
        menu.addItem(resumeRestoresItem)
        menu.addItem(automaticRestoreItem)
        menu.addItem(manageDevicesItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refresh()
        deviceManagerViewModel.refreshRuntimeState()
        updateLaunchAtLoginState()
    }

    private func makePauseMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "暂停自动调节", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(makeMenuItem(title: "暂停 15 分钟", action: #selector(pauseFor15Minutes)))
        submenu.addItem(makeMenuItem(title: "暂停 1 小时", action: #selector(pauseForOneHour)))
        submenu.addItem(makeMenuItem(title: "暂停直到手动恢复", action: #selector(pauseUntilResumed)))
        item.submenu = submenu
        return item
    }

    private func makeVolumeSliderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        let titleLabel = NSTextField(labelWithString: "AirPods 音量")
        let menuItem = NSMenuItem()

        [titleLabel, volumeSlider, volumeValueLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        volumeValueLabel.alignment = .right
        volumeValueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            volumeValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeValueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            volumeValueLabel.widthAnchor.constraint(equalToConstant: 42),

            volumeSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            volumeSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            volumeSlider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])

        menuItem.view = container
        return menuItem
    }

    private func render(_ status: VolumeMemoryStatus) {
        isRenderingStatus = true
        defer { isRenderingStatus = false }
        lastStatus = status

        checkHighVolume(status)
        renderMenuBar(status)
        statusMenuItem.title = status.primaryText
        detailMenuItem.title = status.secondaryText

        if let currentVolume = status.currentVolume {
            let percent = Int((min(max(currentVolume, 0), 1) * 100).rounded())
            volumeSlider.doubleValue = Double(percent)
            volumeValueLabel.stringValue = "\(percent)%"
        } else {
            volumeSlider.doubleValue = 0
            volumeValueLabel.stringValue = "--"
        }

        volumeSlider.isEnabled = status.canAdjustVolume
        saveNowItem.isEnabled = status.canAdjustVolume
        restoreNowItem.isEnabled = status.canAdjustVolume && status.hasRememberedVolume
        automaticRestoreItem.state = status.automaticRestoreEnabled ? .on : .off
        pauseRestoresItem.isHidden = status.restoresPaused
        resumeRestoresItem.isHidden = !status.restoresPaused
        resumeRestoresItem.title = status.pauseDescription.map { "恢复自动调节（暂停：\($0)）" }
            ?? "恢复自动调节"
        deviceManagerViewModel.refreshRuntimeState()
    }

    private func checkHighVolume(_ status: VolumeMemoryStatus) {
        let uid = status.canAdjustVolume ? controller.dataSnapshot().currentDeviceUID : nil
        if highVolumeWarningGate.shouldWarn(
            deviceUID: uid,
            volume: status.currentVolume,
            enabled: preferences.highVolumeWarningEnabled,
            threshold: preferences.highVolumeThreshold
        ), let volume = status.currentVolume {
            notificationManager.deliverHighVolumeWarning(
                deviceName: status.currentDeviceName ?? "AirPods",
                percent: Int((min(max(volume, 0), 1) * 100).rounded()),
                threshold: Int(preferences.highVolumeThreshold.rounded())
            )
        }
    }

    private func renderMenuBar(_ status: VolumeMemoryStatus) {
        guard let button = statusItem.button else { return }
        let percent = status.currentVolume.map { Int((min(max($0, 0), 1) * 100).rounded()) }
        let icon = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPods 音量")
        icon?.isTemplate = true

        switch preferences.menuBarDisplayMode {
        case .iconOnly:
            button.image = icon
            button.title = ""
        case .iconAndPercentage:
            button.image = icon
            button.title = percent.map { " \($0)%" } ?? ""
        case .compactText:
            button.image = nil
            button.title = status.menuBarTitle
        case .deviceName:
            button.image = nil
            if let name = status.currentDeviceName, let percent {
                button.title = "\(name) \(percent)%"
            } else {
                button.title = "AirPods Vol"
            }
        }
        button.toolTip = status.primaryText
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

    @objc private func saveCurrentVolumeNow() {
        controller.saveCurrentVolumeNow()
    }

    @objc private func restoreRememberedVolumeNow() {
        controller.restoreRememberedVolumeNow()
    }

    @objc private func toggleAutomaticRestore() {
        controller.setAutomaticRestoreEnabled(!controller.automaticRestoreEnabled)
    }

    @objc private func pauseFor15Minutes() {
        controller.pauseRestores(for: 15 * 60)
    }

    @objc private func pauseForOneHour() {
        controller.pauseRestores(for: 60 * 60)
    }

    @objc private func pauseUntilResumed() {
        controller.pauseRestores(for: nil)
    }

    @objc private func resumeRestores() {
        controller.resumeRestores()
    }

    @objc func showDeviceManager() {
        deviceManagerWindowController.show()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
            updateLaunchAtLoginState()
        } catch {
            showLaunchAtLoginError(error)
        }
    }

    private func updateLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.state = .on
            launchAtLoginItem.toolTip = nil
        case .requiresApproval:
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.toolTip = "请在“系统设置 > 通用 > 登录项”中允许启动。"
        default:
            launchAtLoginItem.state = .off
            launchAtLoginItem.toolTip = nil
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法更改登录启动设置"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func volumeSliderChanged() {
        guard !isRenderingStatus else {
            return
        }

        controller.setCurrentAirPodsVolume(Float(volumeSlider.doubleValue / 100))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
