import Foundation

enum RestoreHistoryOutcome: String, Codable {
    case pending
    case restored
    case failed
    case paused
    case automaticRestoreOff
    case noRememberedVolume
}

struct RememberedAirPods: Codable, Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    var name: String
    var rememberedVolume: Float
    var lastConnectedAt: Date?
    var lastConnectedVolume: Float?
    var lastRestoredAt: Date?
    var lastRestoredVolume: Float?
    var automaticRestoreEnabled: Bool
}

struct AirPodsConnectionHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let deviceUID: String
    var deviceName: String
    let connectedAt: Date
    var connectedVolume: Float?
    var restoredVolume: Float?
    var outcome: RestoreHistoryOutcome
}

struct VolumeMemoryDataSnapshot {
    let devices: [RememberedAirPods]
    let history: [AirPodsConnectionHistoryEntry]
    let currentDeviceUID: String?
}

struct RestoreNotificationEvent {
    let deviceName: String
    let volume: Float?
    let succeeded: Bool
}

struct VolumeMemoryStatus {
    let menuBarTitle: String
    let primaryText: String
    let secondaryText: String
    let currentVolume: Float?
    let canAdjustVolume: Bool
    let hasRememberedVolume: Bool
    let automaticRestoreEnabled: Bool
    let currentDeviceName: String?
    let restoresPaused: Bool
    let pauseDescription: String?
}

struct VolumeMemoryConfiguration {
    var restoreAttemptDelays: [TimeInterval] = [0.75, 2.25, 5.0]
    var restoreCompletionGrace: TimeInterval = 1.0
    var saveDebounceDelay: TimeInterval = 0.2
}

protocol VolumeMemoryScheduledTask: AnyObject {
    func cancel()
}

protocol VolumeMemoryScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> VolumeMemoryScheduledTask
}

extension DispatchWorkItem: VolumeMemoryScheduledTask {}

struct MainQueueVolumeMemoryScheduler: VolumeMemoryScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> VolumeMemoryScheduledTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return workItem
    }
}

final class VolumeMemoryController {
    var onStatusChanged: ((VolumeMemoryStatus) -> Void)?
    var onDataChanged: ((VolumeMemoryDataSnapshot) -> Void)?
    var onRestoreNotification: ((RestoreNotificationEvent) -> Void)?

    private let defaults: UserDefaults
    private let audioHardware: AudioHardwareControlling
    private let scheduler: VolumeMemoryScheduling
    private let configuration: VolumeMemoryConfiguration
    private let now: () -> Date
    private let savedVolumeKeyPrefix = "savedOutputVolume."
    private let automaticRestoreEnabledKey = "automaticRestoreEnabled"
    private let rememberedDevicesKey = "rememberedAirPods.v2"
    private let connectionHistoryKey = "airPodsConnectionHistory.v1"
    private let restorePausedUntilKey = "restorePausedUntil"
    private let restorePausedIndefinitelyKey = "restorePausedIndefinitely"
    private let maximumHistoryCount = 100

    private var defaultOutputListener: AudioPropertyListening?
    private var volumeListener: AudioPropertyListening?
    private var currentDevice: AudioDevice?
    private var pendingRestoreTasks: [VolumeMemoryScheduledTask] = []
    private var pendingSaveTask: VolumeMemoryScheduledTask?
    private var pendingSettlingTask: VolumeMemoryScheduledTask?
    private var pendingPauseExpirationTask: VolumeMemoryScheduledTask?
    private var restoreTarget: Float?
    private var isRestoreInProgress = false
    private var isConnectionSettling = false
    private var currentHistoryEntryID: UUID?
    private var rememberedDevices: [RememberedAirPods]
    private var connectionHistory: [AirPodsConnectionHistoryEntry]

    init(
        defaults: UserDefaults = .standard,
        audioHardware: AudioHardwareControlling = SystemAudioHardware(),
        scheduler: VolumeMemoryScheduling = MainQueueVolumeMemoryScheduler(),
        configuration: VolumeMemoryConfiguration = VolumeMemoryConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.audioHardware = audioHardware
        self.scheduler = scheduler
        self.configuration = configuration
        self.now = now
        self.rememberedDevices = Self.decode([RememberedAirPods].self, from: defaults, key: rememberedDevicesKey) ?? []
        self.connectionHistory = Self.decode(
            [AirPodsConnectionHistoryEntry].self,
            from: defaults,
            key: connectionHistoryKey
        ) ?? []
    }

    var automaticRestoreEnabled: Bool {
        guard defaults.object(forKey: automaticRestoreEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: automaticRestoreEnabledKey)
    }

    var restoresPaused: Bool {
        if defaults.bool(forKey: restorePausedIndefinitelyKey) {
            return true
        }
        guard let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return false
        }
        if until > now() {
            return true
        }
        defaults.removeObject(forKey: restorePausedUntilKey)
        return false
    }

    var pauseDescription: String? {
        if defaults.bool(forKey: restorePausedIndefinitelyKey) {
            return "直到手动恢复"
        }
        guard restoresPaused, let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return nil
        }
        return "直到 \(Self.pauseDateFormatter.string(from: until))"
    }

    func dataSnapshot() -> VolumeMemoryDataSnapshot {
        VolumeMemoryDataSnapshot(
            devices: rememberedDevices.sorted {
                ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast)
            },
            history: connectionHistory.sorted { $0.connectedAt > $1.connectedAt },
            currentDeviceUID: currentDevice?.isAirPods == true ? currentDevice?.uid : nil
        )
    }

    func pauseRestores(for duration: TimeInterval?) {
        let wasRestoreInProgress = isRestoreInProgress
        cancelRestore()
        if let duration {
            defaults.set(now().addingTimeInterval(duration), forKey: restorePausedUntilKey)
            defaults.set(false, forKey: restorePausedIndefinitelyKey)
        } else {
            defaults.removeObject(forKey: restorePausedUntilKey)
            defaults.set(true, forKey: restorePausedIndefinitelyKey)
        }
        schedulePauseExpirationIfNeeded()

        if let device = currentDevice, device.isAirPods {
            beginConnectionSettling(for: device)
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .paused, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "自动恢复已暂停：\(pauseDescription ?? "临时").")
        } else {
            publishWaitingForAirPods()
        }
    }

    func resumeRestores() {
        defaults.removeObject(forKey: restorePausedUntilKey)
        defaults.set(false, forKey: restorePausedIndefinitelyKey)
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil

        guard let device = currentDevice, device.isAirPods else {
            publishWaitingForAirPods()
            return
        }
        if automaticRestoreEnabled,
           deviceAutomaticRestoreEnabled(device.uid),
           let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "已恢复自动调节。")
        }
    }

    func updateRememberedVolume(for deviceUID: String, volume: Float) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == deviceUID }) else {
            return
        }
        let adjustedVolume = normalizedVolume(volume)
        rememberedDevices[index].rememberedVolume = adjustedVolume
        defaults.set(Double(adjustedVolume), forKey: savedVolumeKey(forUID: deviceUID))
        persistDevices()

        guard let device = currentDevice, device.uid == deviceUID else {
            return
        }
        cancelRestore()
        do {
            try audioHardware.setOutputVolume(adjustedVolume, for: device)
            publishTrackingStatus(
                for: device,
                currentVolume: adjustedVolume,
                note: "已更新此设备的记忆音量。"
            )
        } catch {
            publishError(primary: "已保存记忆音量，但无法应用。", error: error)
        }
    }

    func setAutomaticRestore(_ enabled: Bool, for deviceUID: String) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == deviceUID }) else {
            return
        }
        rememberedDevices[index].automaticRestoreEnabled = enabled
        persistDevices()

        guard let device = currentDevice, device.uid == deviceUID else {
            return
        }

        if !enabled {
            let wasRestoreInProgress = isRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "此设备的自动恢复已关闭。")
        } else if automaticRestoreEnabled, !restoresPaused, let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "此设备的自动恢复已开启。")
        }
    }

    func forgetDevice(_ deviceUID: String) {
        if currentDevice?.uid == deviceUID {
            cancelRestore()
        }
        rememberedDevices.removeAll { $0.uid == deviceUID }
        defaults.removeObject(forKey: savedVolumeKey(forUID: deviceUID))
        persistDevices()

        if let device = currentDevice, device.uid == deviceUID {
            publishCurrentStatus(for: device, note: "已删除记忆音量。")
        }
    }

    func clearConnectionHistory() {
        connectionHistory.removeAll()
        currentHistoryEntryID = nil
        persistHistory()
    }

    func start() {
        stop()
        schedulePauseExpirationIfNeeded()

        do {
            defaultOutputListener = try audioHardware.makeDefaultOutputDeviceListener { [weak self] in
                // A Bluetooth reconnect can reuse the same CoreAudio ID and UID. A real
                // default-output notification must therefore rebuild listeners and restore.
                self?.reconcileDefaultOutputDevice(force: true)
            }
            reconcileDefaultOutputDevice(force: true)
        } catch {
            publishError(
                primary: "无法启动声音设备监听。",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    func stop() {
        cancelRestore()
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil
        isConnectionSettling = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        defaultOutputListener?.invalidate()
        volumeListener?.invalidate()
        defaultOutputListener = nil
        volumeListener = nil
        currentDevice = nil
    }

    func refresh() {
        reconcileDefaultOutputDevice(force: false)
    }

    func handleSystemWake() {
        reconcileDefaultOutputDevice(force: true)
    }

    func setAutomaticRestoreEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: automaticRestoreEnabledKey)

        guard let device = currentDevice, device.isAirPods else {
            publishWaitingForAirPods()
            return
        }

        if !enabled {
            let wasRestoreInProgress = isRestoreInProgress
            cancelRestore()
            if wasRestoreInProgress {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
            }
            publishCurrentStatus(for: device, note: "自动恢复已关闭。")
        } else if restoresPaused {
            cancelRestore()
            publishCurrentStatus(
                for: device,
                note: "自动恢复已开启，但已暂停：\(pauseDescription ?? "临时")."
            )
        } else if !deviceAutomaticRestoreEnabled(device.uid) {
            cancelRestore()
            publishCurrentStatus(for: device, note: "此设备的自动恢复已关闭。")
        } else if let rememberedVolume = savedVolume(for: device) {
            beginRestore(rememberedVolume, for: device, manuallyRequested: false)
        } else {
            publishCurrentStatus(for: device, note: "自动恢复已开启，请先保存音量。")
        }
    }

    func saveCurrentVolumeNow() {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            let volume = normalizedVolume(try audioHardware.outputVolume(for: device))
            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "已保存当前音量。")
        } catch {
            publishError(primary: "无法保存当前音量。", error: error)
        }
    }

    func restoreRememberedVolumeNow() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            guard let rememberedVolume = savedVolume(for: device) else {
                publishCurrentStatus(for: device, note: "暂无记忆音量，请先保存。")
                return
            }

            beginRestore(rememberedVolume, for: device, manuallyRequested: true)
        } catch {
            publishError(primary: "无法恢复记忆音量。", error: error)
        }
    }

    func forgetRememberedVolume() {
        cancelRestore()

        do {
            guard let device = try activeAirPods() else {
                return
            }
            forgetDevice(device.uid)
        } catch {
            publishError(primary: "无法删除记忆音量。", error: error)
        }
    }

    func setCurrentAirPodsVolume(_ volume: Float) {
        cancelRestore()
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        do {
            guard let device = try activeAirPods() else {
                return
            }

            currentDevice = device
            let clampedVolume = normalizedVolume(volume)
            try audioHardware.setOutputVolume(clampedVolume, for: device)
            save(clampedVolume, for: device)
            publishTrackingStatus(for: device, currentVolume: clampedVolume, note: "已调整并保存音量。")
        } catch {
            publishError(primary: "无法调整 AirPods 音量。", error: error)
        }
    }

    private func reconcileDefaultOutputDevice(force: Bool) {
        do {
            let device = try audioHardware.defaultOutputDevice()
            if !force, sameEndpoint(device, currentDevice) {
                if let device {
                    if device.isAirPods {
                        publishCurrentStatus(
                            for: device,
                            note: isRestoreInProgress ? "正在稳定记忆音量…" : nil
                        )
                    } else {
                        publishWaitingForAirPods()
                    }
                } else {
                    publishNoOutputDevice()
                }
                return
            }

            outputDeviceChanged(to: device)
        } catch {
            currentDevice = nil
            publishError(
                primary: "无法读取当前输出设备。",
                error: error,
                canAdjustVolume: false
            )
        }
    }

    private func outputDeviceChanged(to device: AudioDevice?) {
        let reusableHistoryEntryID: UUID? = {
            guard sameEndpoint(device, currentDevice),
                  let currentHistoryEntryID,
                  let entry = connectionHistory.first(where: { $0.id == currentHistoryEntryID }),
                  now().timeIntervalSince(entry.connectedAt) < 10 else {
                return nil
            }
            return currentHistoryEntryID
        }()

        cancelRestore()
        pendingSettlingTask?.cancel()
        pendingSettlingTask = nil
        isConnectionSettling = false
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        volumeListener?.invalidate()
        volumeListener = nil
        currentDevice = device
        currentHistoryEntryID = reusableHistoryEntryID
        publishDataSnapshot()

        guard let device else {
            publishNoOutputDevice()
            return
        }

        guard device.isAirPods else {
            publishWaitingForAirPods()
            return
        }

        installVolumeListener(for: device)
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))
        let rememberedVolume = savedVolume(for: device)
        recordConnection(for: device, connectedVolume: currentVolume)
        beginConnectionSettling(for: device)

        if let rememberedVolume {
            if restoresPaused {
                markCurrentHistory(outcome: .paused, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "已连接；自动恢复已暂停：\(pauseDescription ?? "临时")."
                )
            } else if automaticRestoreEnabled, deviceAutomaticRestoreEnabled(device.uid) {
                beginRestore(rememberedVolume, for: device, manuallyRequested: false)
            } else {
                markCurrentHistory(outcome: .automaticRestoreOff, restoredVolume: nil)
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: automaticRestoreEnabled
                        ? "已连接；此设备的自动恢复已关闭。"
                        : "已连接；自动恢复已关闭。"
                )
            }
        } else if let currentVolume {
            save(currentVolume, for: device)
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
            publishTrackingStatus(
                for: device,
                currentVolume: currentVolume,
                note: "已保存此设备的初始音量。"
            )
        } else {
            markCurrentHistory(outcome: .noRememberedVolume, restoredVolume: nil)
            publish(
                primary: "正在记忆：\(device.name).",
                secondary: "调整一次音量，应用即可记住。",
                currentVolume: nil,
                canAdjustVolume: true,
                hasRememberedVolume: false
            )
        }
    }

    private func installVolumeListener(for device: AudioDevice) {
        guard volumeListener == nil else {
            return
        }

        volumeListener = try? audioHardware.makeVolumeListener(for: device.id) { [weak self] in
            self?.volumeChanged()
        }
    }

    private func beginConnectionSettling(for device: AudioDevice) {
        pendingSettlingTask?.cancel()
        isConnectionSettling = true
        let delay = max(0, configuration.restoreAttemptDelays.max() ?? 0)
            + configuration.restoreCompletionGrace
        pendingSettlingTask = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.isCurrentEndpoint(device) else {
                return
            }
            self.isConnectionSettling = false
            self.pendingSettlingTask = nil
        }
    }

    private func schedulePauseExpirationIfNeeded() {
        pendingPauseExpirationTask?.cancel()
        pendingPauseExpirationTask = nil
        guard !defaults.bool(forKey: restorePausedIndefinitelyKey),
              let until = defaults.object(forKey: restorePausedUntilKey) as? Date else {
            return
        }

        let remaining = until.timeIntervalSince(now())
        guard remaining > 0 else {
            defaults.removeObject(forKey: restorePausedUntilKey)
            return
        }

        pendingPauseExpirationTask = scheduler.schedule(after: remaining) { [weak self] in
            guard let self else { return }
            self.defaults.removeObject(forKey: self.restorePausedUntilKey)
            self.pendingPauseExpirationTask = nil
            if let device = self.currentDevice, device.isAirPods {
                self.publishCurrentStatus(
                    for: device,
                    note: "暂停已结束，下次连接时将自动恢复音量。"
                )
            } else {
                self.publishWaitingForAirPods()
            }
        }
    }

    private func beginRestore(_ volume: Float, for device: AudioDevice, manuallyRequested: Bool) {
        cancelRestore()
        restoreTarget = normalizedVolume(volume)
        isRestoreInProgress = true
        markCurrentHistory(outcome: .pending, restoredVolume: nil)

        let delays = configuration.restoreAttemptDelays.isEmpty ? [0] : configuration.restoreAttemptDelays
        for (index, delay) in delays.enumerated() {
            pendingRestoreTasks.append(
                scheduler.schedule(after: max(0, delay)) { [weak self] in
                    self?.performRestoreAttempt(index: index, totalAttempts: delays.count, for: device)
                }
            )
        }

        let completionDelay = max(0, delays.max() ?? 0) + configuration.restoreCompletionGrace
        pendingRestoreTasks.append(
            scheduler.schedule(after: completionDelay) { [weak self] in
                self?.finishRestore(for: device)
            }
        )

        let target = restoreTarget ?? volume
        publish(
            primary: "正在恢复：\(device.name) 至 \(percent(target)).",
            secondary: manuallyRequested
                ? "正在应用并验证记忆音量。"
                : "正在等待蓝牙音频就绪，随后验证音量。",
            currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
            canAdjustVolume: true,
            hasRememberedVolume: true
        )
    }

    private func performRestoreAttempt(index: Int, totalAttempts: Int, for device: AudioDevice) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        installVolumeListener(for: device)

        do {
            try audioHardware.setOutputVolume(target, for: device)
            let observed = try? normalizedVolume(audioHardware.outputVolume(for: device))
            publish(
                primary: "正在恢复：\(device.name) 至 \(percent(target)).",
                secondary: "验证次数：\(index + 1) / \(totalAttempts).",
                currentVolume: observed ?? target,
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        } catch {
            let willRetry = index + 1 < totalAttempts
            publish(
                primary: willRetry ? "AirPods 尚未就绪。" : "最后一次恢复尝试失败。",
                secondary: willRetry ? "应用将自动重试。" : error.localizedDescription,
                currentVolume: try? normalizedVolume(audioHardware.outputVolume(for: device)),
                canAdjustVolume: true,
                hasRememberedVolume: true
            )
        }
    }

    private func finishRestore(for device: AudioDevice) {
        guard isCurrentEndpoint(device), let target = restoreTarget else {
            return
        }

        isRestoreInProgress = false
        restoreTarget = nil
        pendingRestoreTasks.removeAll()

        do {
            let currentVolume = normalizedVolume(try audioHardware.outputVolume(for: device))
            if volumesMatch(currentVolume, target) {
                recordSuccessfulRestore(for: device, volume: currentVolume)
                markCurrentHistory(outcome: .restored, restoredVolume: currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(deviceName: device.name, volume: currentVolume, succeeded: true)
                )
                publishTrackingStatus(
                    for: device,
                    currentVolume: currentVolume,
                    note: "已恢复记忆音量并验证成功。"
                )
            } else {
                markCurrentHistory(outcome: .failed, restoredVolume: currentVolume)
                onRestoreNotification?(
                    RestoreNotificationEvent(deviceName: device.name, volume: currentVolume, succeeded: false)
                )
                publish(
                    primary: "记忆音量未能保持。",
                    secondary: "请选择“恢复记忆音量”重试。",
                    currentVolume: currentVolume,
                    canAdjustVolume: true,
                    hasRememberedVolume: true
                )
            }
        } catch {
            markCurrentHistory(outcome: .failed, restoredVolume: nil)
            onRestoreNotification?(
                RestoreNotificationEvent(deviceName: device.name, volume: nil, succeeded: false)
            )
            publishError(primary: "无法验证恢复后的音量。", error: error)
        }
    }

    private func cancelRestore() {
        pendingRestoreTasks.forEach { $0.cancel() }
        pendingRestoreTasks.removeAll()
        restoreTarget = nil
        isRestoreInProgress = false
    }

    private func volumeChanged() {
        pendingSaveTask?.cancel()
        pendingSaveTask = scheduler.schedule(after: configuration.saveDebounceDelay) { [weak self] in
            self?.saveChangedVolumeIfNeeded()
        }
    }

    private func saveChangedVolumeIfNeeded() {
        pendingSaveTask = nil
        guard let device = currentDevice, device.isAirPods else {
            return
        }

        do {
            let volume = normalizedVolume(try audioHardware.outputVolume(for: device))
            guard !isRestoreInProgress, !isConnectionSettling else {
                publish(
                    primary: "正在稳定：\(device.name) 于 \(percent(restoreTarget ?? volume)).",
                    secondary: "重连时的临时音量变化不会覆盖记忆值。",
                    currentVolume: volume,
                    canAdjustVolume: true,
                    hasRememberedVolume: savedVolume(for: device) != nil
                )
                return
            }

            if let saved = savedVolume(for: device), volumesMatch(saved, volume) {
                publishTrackingStatus(for: device, currentVolume: volume, note: "音量已同步。")
                return
            }

            save(volume, for: device)
            publishTrackingStatus(for: device, currentVolume: volume, note: "已保存新音量。")
        } catch {
            publishError(primary: "无法保存更改后的音量。", error: error)
        }
    }

    private func publishCurrentStatus(for device: AudioDevice, note: String?) {
        let currentVolume = try? normalizedVolume(audioHardware.outputVolume(for: device))
        publishTrackingStatus(for: device, currentVolume: currentVolume, note: note)
    }

    private func publishTrackingStatus(for device: AudioDevice, currentVolume: Float?, note: String?) {
        let saved = savedVolume(for: device)
        let displayed = currentVolume ?? saved
        publish(
            primary: note ?? "正在记忆：\(device.name).",
            secondary: saved.map { "下次连接将恢复为：\(percent($0))." }
                ?? "调整音量即可保存记忆值。",
            currentVolume: displayed,
            canAdjustVolume: true,
            hasRememberedVolume: saved != nil
        )
    }

    private func activeAirPods() throws -> AudioDevice? {
        guard let device = try audioHardware.defaultOutputDevice() else {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = nil
            publishNoOutputDevice()
            return nil
        }

        guard device.isAirPods else {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = device
            publishWaitingForAirPods()
            return nil
        }

        if !sameEndpoint(device, currentDevice) {
            volumeListener?.invalidate()
            volumeListener = nil
            currentDevice = device
            installVolumeListener(for: device)
        }

        return device
    }

    private func publishNoOutputDevice() {
        publish(
            primary: "当前没有可用的输出设备。",
            secondary: "连接 AirPods 即可开始记忆音量。",
            currentVolume: nil,
            canAdjustVolume: false,
            hasRememberedVolume: false
        )
    }

    private func publishWaitingForAirPods() {
        let deviceName = currentDevice?.name
        publish(
            primary: deviceName.map { "当前输出：\($0)" } ?? "等待 AirPods 连接。",
            secondary: "自动识别 AirPods 和苹果蓝牙耳机。",
            currentVolume: nil,
            canAdjustVolume: false,
            hasRememberedVolume: false
        )
    }

    private func publishError(
        primary: String,
        error: Error,
        canAdjustVolume: Bool = true
    ) {
        let hasRememberedVolume = currentDevice.flatMap(savedVolume(for:)) != nil
        publish(
            primary: primary,
            secondary: error.localizedDescription,
            currentVolume: nil,
            canAdjustVolume: canAdjustVolume,
            hasRememberedVolume: hasRememberedVolume
        )
    }

    private func publish(
        primary: String,
        secondary: String,
        currentVolume: Float?,
        canAdjustVolume: Bool,
        hasRememberedVolume: Bool
    ) {
        let title = currentVolume.map { "AirPods \(percent($0))" } ?? "AirPods Vol"
        onStatusChanged?(
            VolumeMemoryStatus(
                menuBarTitle: title,
                primaryText: primary,
                secondaryText: secondary,
                currentVolume: currentVolume,
                canAdjustVolume: canAdjustVolume,
                hasRememberedVolume: hasRememberedVolume,
                automaticRestoreEnabled: automaticRestoreEnabled,
                currentDeviceName: currentDevice?.isAirPods == true ? currentDevice?.name : nil,
                restoresPaused: restoresPaused,
                pauseDescription: pauseDescription
            )
        )
    }

    private func save(_ volume: Float, for device: AudioDevice) {
        let saved = normalizedVolume(volume)
        if let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) {
            rememberedDevices[index].name = device.name
            rememberedDevices[index].rememberedVolume = saved
        } else {
            rememberedDevices.append(
                RememberedAirPods(
                    uid: device.uid,
                    name: device.name,
                    rememberedVolume: saved,
                    lastConnectedAt: now(),
                    lastConnectedVolume: saved,
                    lastRestoredAt: nil,
                    lastRestoredVolume: nil,
                    automaticRestoreEnabled: true
                )
            )
        }
        defaults.set(Double(saved), forKey: savedVolumeKey(for: device))
        persistDevices()
    }

    private func savedVolume(for device: AudioDevice) -> Float? {
        if let record = rememberedDevices.first(where: { $0.uid == device.uid }) {
            return normalizedVolume(record.rememberedVolume)
        }

        let key = savedVolumeKey(for: device)
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        let legacyVolume = normalizedVolume(Float(defaults.double(forKey: key)))
        rememberedDevices.append(
            RememberedAirPods(
                uid: device.uid,
                name: device.name,
                rememberedVolume: legacyVolume,
                lastConnectedAt: nil,
                lastConnectedVolume: nil,
                lastRestoredAt: nil,
                lastRestoredVolume: nil,
                automaticRestoreEnabled: true
            )
        )
        persistDevices()
        return legacyVolume
    }

    private func savedVolumeKey(for device: AudioDevice) -> String {
        savedVolumeKey(forUID: device.uid)
    }

    private func savedVolumeKey(forUID deviceUID: String) -> String {
        savedVolumeKeyPrefix + deviceUID
    }

    private func deviceAutomaticRestoreEnabled(_ deviceUID: String) -> Bool {
        rememberedDevices.first(where: { $0.uid == deviceUID })?.automaticRestoreEnabled ?? true
    }

    private func recordConnection(for device: AudioDevice, connectedVolume: Float?) {
        let timestamp = now()
        if let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) {
            rememberedDevices[index].name = device.name
            rememberedDevices[index].lastConnectedAt = timestamp
            rememberedDevices[index].lastConnectedVolume = connectedVolume
            persistDevices()
        }

        if currentHistoryEntryID != nil {
            return
        }

        let entry = AirPodsConnectionHistoryEntry(
            id: UUID(),
            deviceUID: device.uid,
            deviceName: device.name,
            connectedAt: timestamp,
            connectedVolume: connectedVolume,
            restoredVolume: nil,
            outcome: .pending
        )
        currentHistoryEntryID = entry.id
        connectionHistory.append(entry)
        if connectionHistory.count > maximumHistoryCount {
            connectionHistory.removeFirst(connectionHistory.count - maximumHistoryCount)
        }
        persistHistory()
    }

    private func recordSuccessfulRestore(for device: AudioDevice, volume: Float) {
        guard let index = rememberedDevices.firstIndex(where: { $0.uid == device.uid }) else {
            return
        }
        rememberedDevices[index].lastRestoredAt = now()
        rememberedDevices[index].lastRestoredVolume = normalizedVolume(volume)
        persistDevices()
    }

    private func markCurrentHistory(outcome: RestoreHistoryOutcome, restoredVolume: Float?) {
        guard let id = currentHistoryEntryID,
              let index = connectionHistory.firstIndex(where: { $0.id == id }) else {
            return
        }
        connectionHistory[index].outcome = outcome
        connectionHistory[index].restoredVolume = restoredVolume.map(normalizedVolume)
        persistHistory()
    }

    private func persistDevices() {
        encode(rememberedDevices, key: rememberedDevicesKey)
        publishDataSnapshot()
    }

    private func persistHistory() {
        encode(connectionHistory, key: connectionHistoryKey)
        publishDataSnapshot()
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private func publishDataSnapshot() {
        onDataChanged?(dataSnapshot())
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func sameEndpoint(_ lhs: AudioDevice?, _ rhs: AudioDevice?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.id == rhs.id && lhs.uid == rhs.uid
        default:
            return false
        }
    }

    private func isCurrentEndpoint(_ device: AudioDevice) -> Bool {
        sameEndpoint(device, currentDevice)
    }

    private func volumesMatch(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(normalizedVolume(lhs) - normalizedVolume(rhs)) < 0.005
    }

    private func percent(_ volume: Float) -> String {
        "\(Int((normalizedVolume(volume) * 100).rounded()))%"
    }

    private func normalizedVolume(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }

    private static let pauseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
