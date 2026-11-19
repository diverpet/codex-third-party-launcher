import AppKit

@MainActor
final class HoverHelpButton: NSButton {
    private let explanationPopover = NSPopover()

    init(explanation: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "GPT 排除说明")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(toggleExplanation)
        toolTip = explanation
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

    @objc private func toggleExplanation() {
        if explanationPopover.isShown {
            explanationPopover.close()
        } else {
            explanationPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }
    }
}
