import AppKit

/// Small translucent pill showing "position / total" over the image.
/// Ignores mouse events so it never blocks clicks on the image.
final class CounterPillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 26))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 13
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        setFrameSize(NSSize(width: label.frame.width + 24, height: 26))
        label.setFrameOrigin(NSPoint(x: 12, y: (26 - label.frame.height) / 2))
    }
}

/// Full-window overlay listing every keyboard shortcut, as currently
/// customized in Settings. Any click dismisses it.
final class ShortcutsOverlayView: NSView {
    var onDismiss: (() -> Void)?

    private let card = NSVisualEffectView()

    /// Mouse gestures and fixed shortcuts that aren't customizable.
    private static let fixedShortcuts: [(String, String)] = [
        ("⌘ Scroll · Pinch", "Continuous zoom"),
        ("Double click", "Toggle fit ↔ actual size"),
        ("⌘,", "Settings (customize shortcuts)"),
    ]

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        // The list is built by reload() each time the overlay is shown.
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the list from the current shortcut bindings.
    func reload() {
        card.subviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .systemFont(ofSize: 15, weight: .bold)

        let text = NSTextField(labelWithAttributedString: Self.buildList())

        title.sizeToFit()
        text.sizeToFit()
        let padding: CGFloat = 28
        let width = max(title.frame.width, text.frame.width) + padding * 2
        let height = title.frame.height + 14 + text.frame.height + padding * 2
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        title.setFrameOrigin(NSPoint(x: padding, y: height - padding - title.frame.height))
        text.setFrameOrigin(NSPoint(x: padding, y: padding))
        card.addSubview(title)
        card.addSubview(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.setFrameOrigin(NSPoint(x: (bounds.width - card.frame.width) / 2,
                                    y: (bounds.height - card.frame.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    private static func entries() -> [(String, String)] {
        let store = ShortcutStore.shared
        let customizable: [(String, String)] = ShortcutAction.allCases.compactMap { action in
            let shortcuts = store.shortcuts(for: action)
            guard !shortcuts.isEmpty else { return nil }
            return (shortcuts.map(\.displayString).joined(separator: "  /  "), action.title)
        }
        return customizable + fixedShortcuts
    }

    private static func buildList() -> NSAttributedString {
        let shortcuts = entries()

        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let keyWidth = shortcuts
            .map { NSAttributedString(string: $0.0, attributes: keyAttrs).size().width }
            .max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: max(150, ceil(keyWidth) + 24))]
        paragraph.lineSpacing = 5

        let out = NSMutableAttributedString()
        for (index, (key, description)) in shortcuts.enumerated() {
            out.append(NSAttributedString(string: key + "\t", attributes: keyAttrs))
            let suffix = index == shortcuts.count - 1 ? "" : "\n"
            out.append(NSAttributedString(string: description + suffix, attributes: descAttrs))
        }
        out.addAttribute(.paragraphStyle, value: paragraph,
                         range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// About overlay: app icon, name, version and license. Any click dismisses it.
final class AboutOverlayView: NSView {
    var onDismiss: (() -> Void)?

    private let card = NSVisualEffectView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.frame = NSRect(x: 0, y: 0, width: 72, height: 72)

        let lines: [(String, NSFont, NSColor)] = [
            ("MViewer", .systemFont(ofSize: 20, weight: .bold), .labelColor),
            ("Version \(version)", .systemFont(ofSize: 12), .secondaryLabelColor),
            ("Fast native image & video viewer for macOS",
             .systemFont(ofSize: 12), .secondaryLabelColor),
            ("github.com/richardogcc/MViewer  ·  MIT License",
             .systemFont(ofSize: 11), .tertiaryLabelColor),
        ]
        let labels: [NSTextField] = lines.map { text, font, color in
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.alignment = .center
            label.sizeToFit()
            return label
        }

        let padding: CGFloat = 32
        let spacing: CGFloat = 8
        let contentWidth = max(labels.map { $0.frame.width }.max() ?? 0, 220)
        let textHeight = labels.reduce(0) { $0 + $1.frame.height } +
            spacing * CGFloat(labels.count - 1)
        let width = contentWidth + padding * 2
        let height = padding + icon.frame.height + 14 + textHeight + padding
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)

        icon.setFrameOrigin(NSPoint(x: (width - icon.frame.width) / 2,
                                    y: height - padding - icon.frame.height))
        var y = height - padding - icon.frame.height - 14
        for label in labels {
            y -= label.frame.height
            label.frame = NSRect(x: padding, y: y, width: contentWidth,
                                 height: label.frame.height)
            card.addSubview(label)
            y -= spacing
        }
        card.addSubview(icon)
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        card.setFrameOrigin(NSPoint(x: (bounds.width - card.frame.width) / 2,
                                    y: (bounds.height - card.frame.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
}
