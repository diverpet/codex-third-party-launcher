import AppKit
import GatewayCore

@MainActor
final class GatewayPrompt: NSObject, NSWindowDelegate {
    struct Selection {
        let address: String
        let key: String
        let contextWindow: Int
        let excludeGPT: Bool
        let includeChatGPT: Bool
    }

    private let window: NSWindow
    private let address = NSTextField()
    private let key = NSSecureTextField()
    private let context = NSTextField()
    private let excludeGPT = NSButton(checkboxWithTitle: "排除 GPT 系列模型（推荐）", target: nil, action: nil)
    private let includeChatGPT = NSButton(checkboxWithTitle: "同时登录 ChatGPT 账户", target: nil, action: nil)
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var selection: Selection?

    init(savedCredentials: GatewayCredentials?) {
        let width: CGFloat = 410
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 320),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "网关配置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let heading = NSTextField(labelWithString: "连接网关")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let header = NSStackView(views: [icon, heading])
        header.alignment = .centerY
        header.spacing = 12

        let instructions = NSTextField(wrappingLabelWithString: savedCredentials == nil
            ? "输入支持 Responses API 的网关地址和密钥。"
            : "密钥留空会使用当前网关已保存的密钥。更换网关或密钥时，请填写新的密钥。")
        instructions.preferredMaxLayoutWidth = width
        instructions.textColor = .secondaryLabelColor
        for field in [address, key, context] {
            field.bezelStyle = .roundedBezel
            field.controlSize = .large
        }
        address.placeholderString = "网关地址"
        address.setAccessibilityLabel("网关地址")
        if let savedCredentials { address.stringValue = savedCredentials.baseURL }
        key.placeholderString = savedCredentials == nil ? "API 密钥" : "API 密钥（留空复用）"
        key.setAccessibilityLabel("API 密钥")
        context.placeholderString = "最大上下文（仅 API 模型，默认 \(Gateway.defaultContextWindow / 1_000)K）"
        context.setAccessibilityLabel("最大上下文")

        excludeGPT.target = self
        excludeGPT.action = #selector(updateChatGPTOption)
        includeChatGPT.isEnabled = false
        includeChatGPT.setAccessibilityHelp("开启 GPT 排除后可选。首次使用时在浏览器授权当前账号。")
        let explanation = """
        Codex Desktop 可能在后台调用 GPT 模型，产生额外用量。
        勾选后隐藏 GPT 模型，并拦截相关请求。
        """
        excludeGPT.setAccessibilityHelp(explanation)
        let help = HoverHelpButton(explanation: explanation)
        let filterRow = NSStackView(views: [excludeGPT, help])
        filterRow.alignment = .centerY
        filterRow.spacing = 6

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelLaunch))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let launch = NSButton(title: "加载模型并启动", target: self, action: #selector(launch))
        launch.bezelStyle = .rounded
        launch.keyEquivalent = "\r"
        window.defaultButtonCell = launch.cell as? NSButtonCell
        let buttons = NSStackView(views: [cancel, launch])
        buttons.spacing = 8
        let footer = NSView()
        footer.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let form = NSStackView(views: [header, instructions, address, key, context, filterRow, includeChatGPT, footer])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.setCustomSpacing(14, after: instructions)
        form.setCustomSpacing(16, after: includeChatGPT)
        let content = NSView()
        content.addSubview(form)
        window.contentView = content
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            form.widthAnchor.constraint(equalToConstant: width),
            icon.widthAnchor.constraint(equalToConstant: 54),
            icon.heightAnchor.constraint(equalToConstant: 54),
            footer.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            instructions.widthAnchor.constraint(equalTo: form.widthAnchor),
            address.widthAnchor.constraint(equalTo: form.widthAnchor),
            key.widthAnchor.constraint(equalTo: form.widthAnchor),
            context.widthAnchor.constraint(equalTo: form.widthAnchor),
        ])
        window.setContentSize(NSSize(width: width + 40, height: form.fittingSize.height + 40))
        window.center()

        address.nextKeyView = key
        key.nextKeyView = context
        context.nextKeyView = excludeGPT
        excludeGPT.nextKeyView = help
        help.nextKeyView = includeChatGPT
        includeChatGPT.nextKeyView = cancel
        cancel.nextKeyView = launch
        launch.nextKeyView = address
        window.initialFirstResponder = address
    }

    func run() async -> Selection? {
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: selection)
    }

    @objc private func updateChatGPTOption() {
        let enabled = excludeGPT.state == .on
        includeChatGPT.isEnabled = enabled
        if !enabled { includeChatGPT.state = .off }
    }

    @objc private func cancelLaunch() { window.close() }

    @objc private func launch() {
        guard window.makeFirstResponder(nil) else { return }
        do {
            let contextWindow = try Gateway.contextWindow(context.stringValue)
            selection = Selection(address: address.stringValue, key: key.stringValue,
                                  contextWindow: contextWindow, excludeGPT: excludeGPT.state == .on,
                                  includeChatGPT: excludeGPT.state == .on && includeChatGPT.state == .on)
            window.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "最大上下文格式无效"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "确定")
            alert.beginSheetModal(for: window) { [weak self] _ in
                guard let self else { return }
                self.window.makeFirstResponder(self.context)
            }
        }
    }
}
