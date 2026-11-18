import AppKit

@MainActor
final class HoverHelpButton: NSButton {
    private let explanationPopover = NSPopover()
    private var hoverArea: NSTrackingArea?

    init(explanation: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "GPT 排除说明")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(toggleExplanation)
        setAccessibilityLabel("GPT 排除说明")
        setAccessibilityHelp(explanation)

        let content = NSViewController()
        let label = NSTextField(wrappingLabelWithString: explanation)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 260
        label.translatesAutoresizingMaskIntoConstraints = false
        content.view = NSView()
        content.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: 260),
        ])
        explanationPopover.contentViewController = content
        explanationPopover.contentSize = NSSize(width: 284, height: label.fittingSize.height + 20)
        explanationPopover.behavior = .transient
        explanationPopover.animates = false
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { showExplanation() }
    override func mouseExited(with event: NSEvent) { dismiss() }

    func dismiss() { explanationPopover.close() }

    @objc private func toggleExplanation() {
        if explanationPopover.isShown { dismiss() } else { showExplanation() }
    }

    private func showExplanation() {
        guard window?.isVisible == true, !explanationPopover.isShown else { return }
        explanationPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
