import AppKit

/// A keycap that records a new shortcut when clicked, or with Space/Return
/// when focused (Delete removes it). With no shortcut it is the "+" add recorder.
/// Knows nothing about the app's actions or store: it reports through its
/// callbacks.
final class ShortcutRecorderView: NSView {
    var onRecord: ((KeyShortcut) -> Void)?
    var onRemove: (() -> Void)?
    /// Keys handed back to the event chain after recording (⌘Q, ⌘W…), so
    /// the menu still handles them. They are reported through `onRecord` too.
    var passesThrough: (KeyShortcut) -> Bool = { _ in false }

    private let shortcut: KeyShortcut?
    private let actionTitle: String
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    /// Only one recorder records at a time.
    private static weak var recording: ShortcutRecorderView?
    private static let cancelShortcut = KeyShortcut(".", .command)

    static func cancelRecording() {
        recording?.stopRecording()
    }

    init(shortcut: KeyShortcut?, actionTitle: String) {
        self.shortcut = shortcut
        self.actionTitle = actionTitle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.font = shortcut == nil ? .systemFont(ofSize: 13, weight: .medium)
                                     : .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: shortcut == nil ? 8 : 4)
        if let shortcut {
            let remove = NSButton.symbol("xmark.circle.fill", target: self, action: #selector(remove(_:)))
            remove.imageScaling = .scaleProportionallyDown
            remove.contentTintColor = .tertiaryLabelColor
            remove.toolTip = "Remove shortcut"
            remove.setAccessibilityLabel("Remove shortcut \(shortcut.displayString) for \(actionTitle)")
            remove.widthAnchor.constraint(equalToConstant: 14).isActive = true
            remove.heightAnchor.constraint(equalToConstant: 14).isActive = true
            stack.addArrangedSubview(remove)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: shortcut == nil ? 28 : 44),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeMonitors()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                                              : NSColor.quaternaryLabelColor).cgColor
        layer?.borderColor = (isRecording ? NSColor.controlAccentColor : NSColor.clear).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording() }
    }

    // MARK: - Keyboard

    /// Focusable from the keyboard only, like buttons: a click records
    /// without leaving a focus ring behind.
    override var acceptsFirstResponder: Bool {
        NSApp.currentEvent.map { ![.leftMouseDown, .rightMouseDown].contains($0.type) } ?? true
    }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func becomeFirstResponder() -> Bool {
        scrollToVisible(bounds.insetBy(dx: 0, dy: -8))
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Repeats of a held key are ignored: holding Space would toggle
        // recording, holding Delete would remove every shortcut in turn. Delete
        // on the add recorder does nothing (no beep).
        switch KeyShortcut(event: event) {
        case .space?, .returnKey?, .enter?:
            guard !event.isARepeat else { return }
            HeldKeyGuard.swallowRepeats(of: event)
            startRecording()
        case .delete?, .forwardDelete?:
            guard !event.isARepeat, shortcut != nil else { return }
            HeldKeyGuard.swallowRepeats(of: event)
            onRemove?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        if let shortcut { return "\(actionTitle) shortcut \(shortcut.displayString)" }
        return "Add shortcut for \(actionTitle)"
    }

    override func accessibilityValue() -> Any? {
        isRecording ? "Recording, type the new shortcut" : nil
    }

    override func accessibilityHelp() -> String? {
        shortcut == nil ? "Records an additional shortcut." :
            "Records a replacement shortcut. Press Delete to remove it."
    }

    override func accessibilityPerformPress() -> Bool {
        isRecording ? stopRecording() : startRecording()
        return true
    }

    // MARK: - Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    @objc private func remove(_ sender: Any?) {
        stopRecording()
        onRemove?()
    }

    // MARK: - Recording

    private func refresh() {
        if isRecording {
            label.stringValue = shortcut == nil ? "Type shortcut…" : "Type new shortcut…"
            label.textColor = .secondaryLabelColor
        } else {
            label.stringValue = shortcut?.displayString ?? "+"
            label.textColor = shortcut == nil ? .secondaryLabelColor : .labelColor
        }
        needsDisplay = true
    }

    private func startRecording() {
        Self.recording?.stopRecording()
        Self.recording = self
        isRecording = true
        refresh()
        NSAccessibility.post(element: self, notification: .valueChanged)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // A key held since before recording started.
            if event.isARepeat { return nil }
            guard let shortcut = KeyShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            self.stopRecording()
            HeldKeyGuard.swallowRepeats(of: event)
            if shortcut == Self.cancelShortcut { return nil }
            self.onRecord?(shortcut)
            return self.passesThrough(shortcut) ? event : nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let inside = event.window === self.window &&
                self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !inside { self.stopRecording() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.stopRecording()
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if Self.recording === self { Self.recording = nil }
        removeMonitors()
        refresh()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil
        mouseMonitor = nil
        resignObserver = nil
    }
}

/// Swallows auto-repeats of a key that was already acted on until it is
/// released, so holding it doesn't re-trigger the menu, beep or move focus.
private enum HeldKeyGuard {
    private static var monitor: Any?

    static func swallowRepeats(of event: NSEvent) {
        stop()
        let keyCode = event.keyCode
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard event.keyCode == keyCode else { return event }
            if event.type == .keyDown && event.isARepeat { return nil }
            stop() // released, or pressed again (a key-up was missed)
            return event
        }
    }

    private static func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension NSButton {
    /// Borderless symbol button. Built without `NSButton(image:target:action:)`,
    /// whose sizeToFit measures the symbol slowly (~5x the cost of this).
    static func symbol(_ name: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = target
        button.action = action
        return button
    }
}
