import AppKit
import SnapWeaveCore
import SnapWeaveCapture
import SnapWeaveMedia

@main
struct SnapWeaveApp {
    static func main() {
        let storageMigration = AppStoragePaths.prepare()
        let application = NSApplication.shared
        let delegate = AppDelegate(storageMigration: storageMigration)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let storageMigration: AppStorageMigrationResult
    private var statusItem: NSStatusItem!
    private let hotKeyRegistry = GlobalHotKeyRegistry()
    private let coordinator = CaptureCoordinator()
    private let historyService = ClipboardHistoryService()
    private let screenshotHistoryService = ScreenshotHistoryService.shared
    private let updateService = UpdateServiceFactory.make()
    private lazy var historyController = ClipboardHistoryWindowController(service: historyService) { [weak self] image in
        self?.coordinator.editClipboardImage(image)
    }
    private lazy var screenshotHistoryController = ScreenshotHistoryWindowController(service: screenshotHistoryService) { [weak self] loaded in
        self?.coordinator.editScreenshotProject(loaded)
    }
    private var preferencesController: PreferencesWindowController?
    private lazy var menuPanel = MenuPanelController(actions: .init(
        standard: { [weak self] in self?.standardCapture() },
        delayed: { [weak self] in self?.delayedCapture() },
        vertical: { [weak self] in self?.verticalCapture() },
        horizontal: { [weak self] in self?.horizontalCapture() },
        pin: { [weak self] in self?.pinRegion() },
        text: { [weak self] in self?.extractText() },
        gif: { [weak self] in self?.recordGIF() },
        history: { [weak self] in self?.showClipboardHistory() },
        recentScreenshots: { [weak self] in self?.showRecentScreenshots() },
        permissions: { [weak self] in self?.checkPermissions() },
        preferences: { [weak self] in self?.openPreferences() },
        diagnostics: { DiagnosticBundleExporter.present() },
        quit: { NSApplication.shared.terminate(nil) }
    ))

    init(storageMigration: AppStorageMigrationResult) {
        self.storageMigration = storageMigration
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillSleep), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceDidWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidResignActive), name: NSApplication.didResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        DiagnosticLogger.shared.log("lifecycle", "application_ready", fields: ["automaticUpdates": updateService.isAvailable ? "enabled" : "disabled"])
        logStorageMigration()
        hotKeyRegistry.install(name: "capture", id: 1) { [weak self] in self?.standardCapture() }
        hotKeyRegistry.install(name: "pin", id: 2) { [weak self] in self?.pinRegion() }
        hotKeyRegistry.install(name: "text", id: 3) { [weak self] in self?.extractText() }
        hotKeyRegistry.install(name: "gif", id: 4) { [weak self] in self?.recordGIF() }
        hotKeyRegistry.install(name: "history", id: 5) { [weak self] in self?.showClipboardHistory() }
        if case let .failure(error) = hotKeyRegistry.apply(AppPreferences.shared.allHotKeyBindings) {
            DiagnosticLogger.shared.log("hotkey", "initial_registration_failed", fields: ["reason": error.localizedDescription])
        }
        if AppPreferences.shared.clipboardHistoryEnabled && AppPreferences.shared.clipboardHistoryConsentCompleted {
            historyService.start()
        }
        coordinator.onGIFRecordingStateChange = { [weak self] recording in
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: recording ? "record.circle.fill" : "viewfinder",
                accessibilityDescription: recording ? "GIF 正在录制" : "SnapWeave"
            )
        }
        if !PermissionManager.canCaptureScreen {
            showPermissionIntroduction()
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SnapWeave")
        statusItem.button?.toolTip = "SnapWeave"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMenuPanel)
    }

    @objc private func toggleMenuPanel() {
        guard let button = statusItem.button else { return }
        menuPanel.toggle(relativeTo: button)
    }

    @objc private func standardCapture() { DiagnosticLogger.shared.log("capture", "standard_started"); coordinator.begin(mode: .standard) }
    @objc private func delayedCapture() { DiagnosticLogger.shared.log("capture", "delayed_started"); coordinator.beginDelayedCapture() }
    @objc private func verticalCapture() { DiagnosticLogger.shared.log("capture", "vertical_started"); coordinator.begin(mode: .vertical) }
    @objc private func horizontalCapture() { DiagnosticLogger.shared.log("capture", "horizontal_started"); coordinator.begin(mode: .horizontal) }
    @objc private func pinRegion() { DiagnosticLogger.shared.log("capture", "pin_started"); coordinator.beginPin() }
    @objc private func extractText() { DiagnosticLogger.shared.log("capture", "ocr_started"); coordinator.beginTextExtraction() }
    @objc private func recordGIF() { DiagnosticLogger.shared.log("capture", "gif_toggled"); coordinator.beginGIFRecording() }
    @objc private func showClipboardHistory() { openClipboardHistory() }
    @objc private func showRecentScreenshots() { openRecentScreenshots() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func checkPermissions() {
        PermissionWindow.show()
    }

    @objc private func openPreferences() {
        let controller = PreferencesWindowController(onApplyHotKeys: { [weak self] bindings in
            guard let self else { return .success(()) }
            return self.hotKeyRegistry.apply(bindings)
        }, onChange: { [weak self] in
            guard let self else { return }
            if AppPreferences.shared.clipboardHistoryEnabled { self.historyService.start() }
            else { self.historyService.stop() }
        }, onClearHistory: { [weak self] in self?.historyService.clearAll() },
        onClearScreenshotHistory: { [weak self] in self?.screenshotHistoryService.clearAll() })
        preferencesController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.cancelGIFRecording()
        CaptureContentProvider.shared.cancelPendingRequest()
        historyService.stop()
        GIFTemporaryFiles.cleanupStaleFiles()
        DiagnosticLogger.shared.finishSession()
    }

    @objc private func workspaceWillSleep() { historyService.suspend() }
    @objc private func workspaceDidWake() { historyService.resume() }
    @objc private func applicationDidResignActive() {
        historyService.trimCaches()
        screenshotHistoryService.trimCaches()
    }
    @objc private func screenParametersChanged() { CaptureContentProvider.shared.invalidate() }

    private func openClipboardHistory() {
        if !AppPreferences.shared.clipboardHistoryConsentCompleted {
            let alert = NSAlert()
            alert.messageText = "启用剪贴板历史？"
            alert.informativeText = "SnapWeave 会从现在开始，把文字、链接、富文本和静态图片保存在本机，最长 30 天、最多 100 条。不会记录 GIF、文件、音视频及带密码或临时标记的内容；未正确标记的敏感内容仍可能被记录。当前剪贴板内容不会被导入。"
            alert.addButton(withTitle: "同意并启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AppPreferences.shared.clipboardHistoryConsentCompleted = true
            AppPreferences.shared.clipboardHistoryEnabled = true
            historyService.start()
        } else if !AppPreferences.shared.clipboardHistoryEnabled {
            let alert = NSAlert()
            alert.messageText = "剪贴板历史已关闭"
            alert.informativeText = "是否重新启用？启用前已有的剪贴板内容不会被导入。"
            alert.addButton(withTitle: "重新启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AppPreferences.shared.clipboardHistoryEnabled = true
            historyService.start()
        }
        historyController.presentNearMouse()
    }

    private func openRecentScreenshots() {
        if !AppPreferences.shared.screenshotHistoryConsentCompleted {
            let alert = NSAlert()
            alert.messageText = "启用最近截图？"
            alert.informativeText = "启用后，SnapWeave 会把新截图的原始底图和可编辑标注图层保存在本机，最长 30 天、最多 100 条、总容量最多 2GB。GIF、OCR、钉图和剪贴板内容不会进入最近截图。"
            alert.addButton(withTitle: "同意并启用")
            alert.addButton(withTitle: "仅查看现有记录")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                AppPreferences.shared.screenshotHistoryConsentCompleted = true
                AppPreferences.shared.screenshotHistoryEnabled = true
            }
        } else if !AppPreferences.shared.screenshotHistoryEnabled {
            let alert = NSAlert()
            alert.messageText = "截图历史记录已关闭"
            alert.informativeText = "现有记录仍可查看。重新启用后，只会记录之后的新截图。"
            alert.addButton(withTitle: "查看现有记录")
            alert.addButton(withTitle: "重新启用")
            if alert.runModal() == .alertSecondButtonReturn { AppPreferences.shared.screenshotHistoryEnabled = true }
        }
        screenshotHistoryController.present()
    }

    private func showPermissionIntroduction() {
        let alert = NSAlert()
        alert.messageText = "欢迎使用 SnapWeave"
        alert.informativeText = "截图需要“屏幕录制”权限。滚动截图默认由你手动滚动；只有主动切换到自动滚动时才需要“辅助功能”权限。所有图片和文字识别都只在本机处理。"
        alert.addButton(withTitle: "开始授权")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = PermissionManager.requestScreenCapture()
        }
    }

    private func logStorageMigration() {
        switch storageMigration {
        case .notNeeded:
            DiagnosticLogger.shared.log("storage", "brand_migration_not_needed")
        case .usingCurrent:
            DiagnosticLogger.shared.log("storage", "using_snapweave_directory")
        case .migrated:
            DiagnosticLogger.shared.log("storage", "legacy_directory_migrated")
        case .bothPresent:
            DiagnosticLogger.shared.log("storage", "both_brand_directories_present", fields: ["resolution": "using_snapweave_without_merge"])
        case let .failed(reason):
            DiagnosticLogger.shared.log("storage", "legacy_directory_migration_failed", fields: ["reason": reason])
        }
    }
}
