import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private enum Section: Int, CaseIterable {
        case general, shortcuts, capture, screenshotHistory, clipboard, diagnostics, about
        var title: String {
            switch self {
            case .general: "通用"
            case .shortcuts: "快捷键"
            case .capture: "截图与拼接"
            case .screenshotHistory: "截图历史"
            case .clipboard: "剪贴板历史"
            case .diagnostics: "诊断"
            case .about: "关于"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .capture: "viewfinder"
            case .screenshotHistory: "photo.stack"
            case .clipboard: "clipboard"
            case .diagnostics: "stethoscope"
            case .about: "info.circle"
            }
        }
    }

    private let onApplyHotKeys: ([String: HotKeyBinding]) -> Result<Void, HotKeyRegistrationError>
    private let onChange: () -> Void
    private let onClearHistory: () -> Void
    private let onClearScreenshotHistory: () -> Void
    private let contentContainer = NSView()
    private let sectionTitle = NSTextField(labelWithString: "")
    private var sectionViews: [Section: NSView] = [:]
    private var sidebarButtons: [Section: NSButton] = [:]

    private let formatPopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时启动 SnapWeave", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "启用剪贴板历史（仅本机保存）", target: nil, action: nil)
    private let screenshotHistoryCheckbox = NSButton(checkboxWithTitle: "自动保存最近截图和可编辑草稿", target: nil, action: nil)
    private let delayPopup = NSPopUpButton()
    private let shortcutErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let recorders: [String: ShortcutRecorderControl] = [
        "capture": ShortcutRecorderControl(), "pin": ShortcutRecorderControl(), "text": ShortcutRecorderControl(),
        "gif": ShortcutRecorderControl(), "history": ShortcutRecorderControl()
    ]

    init(
        onApplyHotKeys: @escaping ([String: HotKeyBinding]) -> Result<Void, HotKeyRegistrationError>,
        onChange: @escaping () -> Void,
        onClearHistory: @escaping () -> Void,
        onClearScreenshotHistory: @escaping () -> Void
    ) {
        self.onApplyHotKeys = onApplyHotKeys
        self.onChange = onChange
        self.onClearHistory = onClearHistory
        self.onClearScreenshotHistory = onClearScreenshotHistory
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "SnapWeave 设置"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let root = window?.contentView else { return }
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 5
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)
        for section in Section.allCases {
            let button = NSButton(title: section.title, target: self, action: #selector(selectSection(_:)))
            button.tag = section.rawValue
            button.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.bezelStyle = .recessed
            button.isBordered = false
            button.widthAnchor.constraint(equalToConstant: 145).isActive = true
            sidebarButtons[section] = button
            sidebarStack.addArrangedSubview(button)
        }

        sectionTitle.font = .systemFont(ofSize: 22, weight: .bold)
        sectionTitle.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sectionTitle)
        root.addSubview(contentContainer)

        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(save)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 178),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            sectionTitle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 28),
            sectionTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            contentContainer.leadingAnchor.constraint(equalTo: sectionTitle.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            contentContainer.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 18),
            contentContainer.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])

        loadValues()
        sectionViews = [
            .general: generalView(), .shortcuts: shortcutsView(), .capture: captureView(),
            .screenshotHistory: screenshotHistoryView(), .clipboard: clipboardView(),
            .diagnostics: diagnosticsView(), .about: aboutView()
        ]
        show(.general)
    }

    private func loadValues() {
        formatPopup.addItems(withTitles: ["PNG", "JPEG"])
        formatPopup.selectItem(withTitle: AppPreferences.shared.saveFormat.uppercased())
        loginCheckbox.state = AppPreferences.shared.launchesAtLogin ? .on : .off
        historyCheckbox.state = AppPreferences.shared.clipboardHistoryEnabled ? .on : .off
        screenshotHistoryCheckbox.state = AppPreferences.shared.screenshotHistoryEnabled ? .on : .off
        delayPopup.addItems(withTitles: ["3 秒", "5 秒", "10 秒"])
        delayPopup.selectItem(at: [3, 5, 10].firstIndex(of: AppPreferences.shared.delayedCaptureSeconds) ?? 0)
        let values: [String: HotKeyBinding] = [
            "capture": AppPreferences.shared.captureBinding, "pin": AppPreferences.shared.pinBinding,
            "text": AppPreferences.shared.textBinding, "gif": AppPreferences.shared.gifBinding,
            "history": AppPreferences.shared.historyBinding
        ]
        for (name, recorder) in recorders {
            recorder.binding = AppPreferences.shared.disabledHotKeys.contains(name) ? nil : values[name]
            recorder.target = self
            recorder.action = #selector(shortcutChanged)
            recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 31).isActive = true
        }
    }

    private func generalView() -> NSView {
        let note = secondary("SnapWeave 常驻菜单栏，不显示 Dock 图标。所有截图和文字内容均在本机处理。")
        return vertical([row("默认保存格式", formatPopup), loginCheckbox, note])
    }

    private func shortcutsView() -> NSView {
        let names = [("capture", "普通截图"), ("pin", "钉住区域"), ("text", "提取文字"), ("gif", "录制 GIF"), ("history", "剪贴板历史")]
        let rows = names.compactMap { name, title in recorders[name].map { row(title, $0) } }
        shortcutErrorLabel.textColor = .systemRed
        shortcutErrorLabel.maximumNumberOfLines = 2
        let reset = NSButton(title: "恢复默认快捷键", target: self, action: #selector(resetShortcuts))
        reset.bezelStyle = .rounded
        return vertical(rows + [shortcutErrorLabel, reset, secondary("点击组合框后直接按下新快捷键；Delete 可关闭该功能的全局快捷键。")])
    }

    private func captureView() -> NSView {
        let delay = row("延时截图默认倒计时", delayPopup)
        let selection = secondary("框选时可在浮动栏切换自由选区、1:1、4:3、16:9、自定义比例或固定像素尺寸；每次新截图默认恢复为自由选区。")
        let title = label("安全拼接策略")
        let body = secondary("滚动截图默认手动。SnapWeave 会使用连续帧、多尺度边缘匹配和重复纹理检查；画面不稳定或重叠不足时会暂停，已完成部分不会丢失。")
        let limits = secondary("长边最多 100,000 像素，总图像最多 2 亿像素。自动滚动仅在鼠标位于选区内时发送滚轮事件。")
        return vertical([delay, selection, title, body, limits])
    }

    private func screenshotHistoryView() -> NSView {
        let clear = NSButton(title: "清空全部最近截图…", target: self, action: #selector(clearScreenshotHistory))
        clear.bezelStyle = .rounded
        return vertical([
            screenshotHistoryCheckbox,
            secondary("开启后会把普通截图、横向长图和纵向长图的原始底图与标注工程保存在本机。最长 30 天、最多 100 条、总容量最多 2GB。关闭后不再新增或更新，已有记录默认保留。"),
            clear
        ])
    }

    private func clipboardView() -> NSView {
        let clear = NSButton(title: "清空全部剪贴板历史…", target: self, action: #selector(clearAllHistory))
        clear.bezelStyle = .rounded
        return vertical([historyCheckbox, secondary("保存文字、链接、富文本和静态图片，最多 100 条、30 天、1GB。图片只生成缩略图，不进行 OCR 搜索。"), clear])
    }

    private func diagnosticsView() -> NSView {
        let export = NSButton(title: "导出问题诊断…", target: self, action: #selector(exportDiagnostics))
        export.bezelStyle = .rounded
        return vertical([secondary("诊断包包含最近 7 天的 SnapWeave 运行日志、系统环境、权限状态和可读取的崩溃报告。不会包含截图、GIF、OCR、剪贴板正文或快捷键配置。"), export])
    }

    private func aboutView() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.12.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "16"
        return vertical([label("SnapWeave \(version) (\(build))"), secondary("原生 macOS 截图工具 · MIT License\nApple Silicon · macOS 14 或更高版本")])
    }

    private func vertical(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        return stack
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let titleLabel = label(title)
        titleLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let spacer = NSView()
        let stack = NSStackView(views: [titleLabel, spacer, control])
        stack.alignment = .centerY
        stack.widthAnchor.constraint(equalToConstant: 455).isActive = true
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let value = NSTextField(labelWithString: text)
        value.font = .systemFont(ofSize: 13, weight: .medium)
        return value
    }

    private func secondary(_ text: String) -> NSTextField {
        let value = NSTextField(wrappingLabelWithString: text)
        value.textColor = .secondaryLabelColor
        value.maximumNumberOfLines = 0
        value.preferredMaxLayoutWidth = 455
        return value
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = Section(rawValue: sender.tag) else { return }
        show(section)
    }

    private func show(_ section: Section) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let sectionView = sectionViews[section] else { return }
        sectionTitle.stringValue = section.title
        sidebarButtons.forEach { $0.value.state = $0.key == section ? .on : .off }
        sectionView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(sectionView)
        NSLayoutConstraint.activate([
            sectionView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            sectionView.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
            sectionView.topAnchor.constraint(equalTo: contentContainer.topAnchor)
        ])
    }

    @objc private func shortcutChanged() { validateShortcutDraft() }

    private func validateShortcutDraft() {
        let values = recorders.values.compactMap(\.binding)
        shortcutErrorLabel.stringValue = Set(values).count == values.count ? "" : "快捷键冲突：多个功能不能使用相同组合。"
    }

    @objc private func resetShortcuts() {
        recorders["capture"]?.binding = .captureDefault
        recorders["pin"]?.binding = .pinDefault
        recorders["text"]?.binding = .textDefault
        recorders["gif"]?.binding = .gifDefault
        recorders["history"]?.binding = .historyDefault
        validateShortcutDraft()
    }

    @objc private func saveSettings() {
        let bindings = recorders.compactMapValues(\.binding)
        guard Set(bindings.values).count == bindings.count else { validateShortcutDraft(); NSSound.beep(); return }
        let enableHistory = historyCheckbox.state == .on
        let enableScreenshotHistory = screenshotHistoryCheckbox.state == .on
        if enableHistory && !AppPreferences.shared.clipboardHistoryConsentCompleted {
            let alert = NSAlert()
            alert.messageText = "启用剪贴板历史？"
            alert.informativeText = "SnapWeave 会从启用后开始，把文字、链接、富文本和静态图片保存在本机。未正确标记的敏感内容仍可能被记录。"
            alert.addButton(withTitle: "同意并启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AppPreferences.shared.clipboardHistoryConsentCompleted = true
        }
        if enableScreenshotHistory && !AppPreferences.shared.screenshotHistoryConsentCompleted {
            let alert = NSAlert()
            alert.messageText = "启用最近截图？"
            alert.informativeText = "SnapWeave 会把新截图的原始底图和可编辑标注图层保存在本机。GIF、OCR、钉图和剪贴板内容不会进入最近截图。"
            alert.addButton(withTitle: "同意并启用")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AppPreferences.shared.screenshotHistoryConsentCompleted = true
        }
        switch onApplyHotKeys(bindings) {
        case let .failure(error):
            shortcutErrorLabel.stringValue = error.localizedDescription
            show(.shortcuts)
            return
        case .success: break
        }
        if let value = bindings["capture"] { AppPreferences.shared.captureBinding = value }
        if let value = bindings["pin"] { AppPreferences.shared.pinBinding = value }
        if let value = bindings["text"] { AppPreferences.shared.textBinding = value }
        if let value = bindings["gif"] { AppPreferences.shared.gifBinding = value }
        if let value = bindings["history"] { AppPreferences.shared.historyBinding = value }
        AppPreferences.shared.disabledHotKeys = Set(recorders.keys.filter { recorders[$0]?.binding == nil })
        AppPreferences.shared.clipboardHistoryEnabled = enableHistory
        if AppPreferences.shared.screenshotHistoryEnabled && !enableScreenshotHistory {
            let alert = NSAlert()
            alert.messageText = "关闭截图历史记录？"
            alert.informativeText = "关闭后不再保存新截图或更新草稿。已有记录可以保留，也可以立即全部清空。"
            alert.addButton(withTitle: "关闭并保留")
            alert.addButton(withTitle: "关闭并清空")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            if response == .alertSecondButtonReturn { onClearScreenshotHistory() }
        }
        AppPreferences.shared.screenshotHistoryEnabled = enableScreenshotHistory
        AppPreferences.shared.delayedCaptureSeconds = [3, 5, 10][max(0, delayPopup.indexOfSelectedItem)]
        AppPreferences.shared.saveFormat = (formatPopup.titleOfSelectedItem ?? "PNG").lowercased()
        do { try AppPreferences.shared.setLaunchAtLogin(loginCheckbox.state == .on) }
        catch {
            let alert = NSAlert(error: error)
            alert.informativeText += "\n请先将 SnapWeave.app 移到‘应用程序’文件夹。"
            alert.runModal()
        }
        onChange()
        close()
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "固定记录也会被删除，此操作无法撤销。"
        alert.addButton(withTitle: "全部清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { onClearHistory() }
    }

    @objc private func clearScreenshotHistory() {
        let alert = NSAlert()
        alert.messageText = "清空全部最近截图？"
        alert.informativeText = "底图、缩略图和可编辑标注工程都会被删除，此操作无法撤销。"
        alert.addButton(withTitle: "全部清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { onClearScreenshotHistory() }
    }

    @objc private func exportDiagnostics() { DiagnosticBundleExporter.present() }
}
