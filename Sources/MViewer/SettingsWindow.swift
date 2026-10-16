import AppKit

/// Settings window (⌘,) with toolbar-style panes.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let shortcuts = NSTabViewItem(viewController: ShortcutsSettingsViewController())
        shortcuts.label = "Shortcuts"
        shortcuts.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcuts")
        tabs.addTabViewItem(shortcuts)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        // Opens over a full-screen viewer and on the current Space.
        window.collectionBehavior.formUnion([.fullScreenAuxiliary, .moveToActiveSpace])
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Lists every customizable action with its shortcuts. Click a shortcut to
/// re-record it, + to add one, × to remove one. A plain stack of rows (not a
/// table) so every row exists and Tab walks through them in order.
/// The only Settings code that talks to the store.
final class ShortcutsSettingsViewController: NSViewController {
    private enum Row {
        case header(String)
        case action(ShortcutAction)
    }

    private enum Layout {
        static let rowInsets = NSEdgeInsets(top: 0, left: 20, bottom: 12, right: 12)
        static let rowHeight: CGFloat = 30
        static let firstHeaderHeight: CGFloat = 24
        static let headerHeight: CGFloat = 36
        static let labelWidth: CGFloat = 240
        static let labelGap: CGFloat = 6
    }

    private let rows: [Row] = ShortcutAction.Category.allCases.flatMap { category in
        [Row.header(category.title)] + category.actions.map(Row.action)
    }

    private let store: ShortcutStore
    private let rowsStack = NSStackView()
    private var listViews: [ShortcutAction: ShortcutListView] = [:]
    private var actionRows: [ShortcutAction: NSView] = [:]
    private let statusLabel = NSTextField(labelWithString: "")
    private var storeObserver: NSObjectProtocol?

    init(store: ShortcutStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let storeObserver { store.notificationCenter.removeObserver(storeObserver) }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))

        let intro = NSTextField(wrappingLabelWithString:
            "Click a shortcut to change it, + to add another, or × to remove it. " +
            "Almost any key can be recorded, Esc included; click elsewhere or press ⌘. to cancel. " +
            "From the keyboard: Tab to a shortcut, then Space to record or Delete to remove it.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 12)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.edgeInsets = Layout.rowInsets
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        NSLayoutConstraint.activate([
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let restore = NSButton(title: "Restore Defaults", target: self,
                               action: #selector(restoreDefaults(_:)))

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for view in [intro, scrollView, restore, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            restore.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            restore.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            restore.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            statusLabel.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: restore.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])

        view = root
        preferredContentSize = root.frame.size

        buildRows()
        // Synchronous (no queue), so rows are updated before focus is restored.
        storeObserver = store.notificationCenter.addObserver(
            forName: ShortcutStore.didChange, object: store, queue: nil
        ) { [weak self] _ in
            self?.updateChangedRows()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateKeyViewLoop()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        ShortcutRecorderView.cancelRecording()
        statusLabel.stringValue = ""
    }

    // MARK: - Editing

    private func record(_ shortcut: KeyShortcut, for action: ShortcutAction, replacing index: Int?) {
        keepingFocus {
            if store.isReserved(shortcut) {
                // The recorder already handed the key to the menu bar.
                statusLabel.stringValue = "\(shortcut.displayString) is reserved for the system."
                return nil
            }
            let owner = store.assign(shortcut, to: action, replacing: index)
            statusLabel.stringValue = owner.map {
                "\(shortcut.displayString) was removed from “\($0.title)”."
            } ?? ""
            let list = store.shortcuts(for: action)
            return (action, list.firstIndex(of: shortcut) ?? list.count)
        }
    }

    private func remove(at index: Int, from action: ShortcutAction) {
        keepingFocus {
            statusLabel.stringValue = ""
            store.remove(at: index, from: action)
            return (action, index)
        }
    }

    private func reset(_ action: ShortcutAction) {
        keepingFocus {
            let touched = store.reset(action)
            let names = touched.map { "“\($0.title)”" }.joined(separator: ", ")
            statusLabel.stringValue = touched.isEmpty ? "" :
                "Restored “\(action.title)”; its defaults were removed from \(names)."
            return (action, 0)
        }
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore all shortcuts to their defaults?"
        alert.informativeText = "Your custom shortcuts will be lost."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.keepingFocus {
                self.store.resetAll()
                self.statusLabel.stringValue = ""
                return nil
            }
        }
    }

    // MARK: - Focus

    /// Runs an edit, which replaces the shortcut lists it changes. If that
    /// replaced the focused view, puts keyboard focus back in the same action,
    /// in order of preference: the same shortcut if it survived; the recorder
    /// the edit returns if it edited that action (keyboard record/Delete); the
    /// reset arrow if it had focus and still exists; else the old position.
    /// Focus elsewhere is left alone, so a mouse edit in another row doesn't
    /// move it.
    private func keepingFocus(_ edit: () -> (action: ShortcutAction, recorderIndex: Int)?) {
        let focused = view.window?.firstResponder as? NSView
        let focusedAction = self.focusedAction
        let oldList = focusedAction.flatMap { listViews[$0] }
        let oldIndex = focused.flatMap { oldList?.recorderIndex(containing: $0) }
        let oldShortcut = oldIndex.flatMap { index in
            oldList.flatMap { index < $0.shortcuts.count ? $0.shortcuts[index] : nil }
        }

        let target = edit()

        guard let action = focusedAction, focused?.window == nil, let list = listViews[action] else { return }
        let next: NSView
        if let oldShortcut, let index = list.shortcuts.firstIndex(of: oldShortcut) {
            next = list.recorder(at: index)
        } else if let target, target.action == action {
            next = list.recorder(at: target.recorderIndex)
        } else if oldIndex == nil, let reset = list.resetButton {
            next = reset
        } else {
            next = list.recorder(at: oldIndex ?? 0)
        }
        view.window?.makeFirstResponder(next)
    }

    /// The action whose shortcuts have keyboard focus, if any.
    private var focusedAction: ShortcutAction? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        return listViews.first { responder.isDescendant(of: $0.value) }?.key
    }

    /// Shortcut lists are replaced on change: relink the Tab order top to bottom,
    /// starting at the first shortcut (the tab view controller otherwise
    /// points the first Tab at a view that can't take focus).
    private func updateKeyViewLoop() {
        guard let window = view.window else { return }
        window.recalculateKeyViewLoop()
        let firstAction = rows.lazy.compactMap { row -> ShortcutAction? in
            if case .action(let action) = row { return action }
            return nil
        }.first
        window.initialFirstResponder = firstAction.flatMap { listViews[$0]?.recorder(at: 0) }
    }

    // MARK: - Rows

    private func buildRows() {
        for row in rows {
            let rowView = NSView()
            switch row {
            case .header(let title):
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 12, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(label)
                let height = rowsStack.arrangedSubviews.isEmpty ? Layout.firstHeaderHeight : Layout.headerHeight
                NSLayoutConstraint.activate([
                    rowView.heightAnchor.constraint(equalToConstant: height),
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
                    label.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -4),
                ])
            case .action(let action):
                let label = NSTextField(labelWithString: action.title)
                label.lineBreakMode = .byTruncatingTail
                label.toolTip = action.title
                label.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(label)
                NSLayoutConstraint.activate([
                    rowView.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
                    label.widthAnchor.constraint(equalToConstant: Layout.labelWidth),
                    label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
                ])
                actionRows[action] = rowView
                installList(for: action)
            }
            rowsStack.addArrangedSubview(rowView)
            let insets = Layout.rowInsets.left + Layout.rowInsets.right
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -insets).isActive = true
        }
        updateKeyViewLoop()
    }

    /// Replaces only the lists whose shortcuts changed; most edits touch a few
    /// actions, and rebuilding every row stalls for ~100 ms.
    private func updateChangedRows() {
        let changed = ShortcutAction.allCases.filter { listViews[$0]?.shortcuts != store.shortcuts(for: $0) }
        guard !changed.isEmpty else { return }
        changed.forEach(installList(for:))
        updateKeyViewLoop()
    }

    private func installList(for action: ShortcutAction) {
        guard let rowView = actionRows[action] else { return }
        listViews[action]?.removeFromSuperview()

        let list = ShortcutListView(shortcuts: store.shortcuts(for: action),
                                    actionTitle: action.title,
                                    isCustomized: !store.isDefault(action),
                                    maxCount: ShortcutStore.maxShortcutsPerAction,
                                    passesThrough: store.isReserved)
        list.onRecord = { [weak self] shortcut, index in
            self?.record(shortcut, for: action, replacing: index)
        }
        list.onRemove = { [weak self] index in self?.remove(at: index, from: action) }
        list.onReset = { [weak self] in self?.reset(action) }
        listViews[action] = list

        list.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: rowView.leadingAnchor,
                                          constant: Layout.labelWidth + Layout.labelGap),
            list.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
            list.topAnchor.constraint(equalTo: rowView.topAnchor),
            list.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
        ])
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One action's shortcuts as recorders, an add recorder and, when customized,
/// a reset button.
private final class ShortcutListView: NSView {
    var onRecord: ((KeyShortcut, Int?) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onReset: (() -> Void)?

    /// The shortcuts this list shows, to tell when it is out of date.
    let shortcuts: [KeyShortcut]
    private var recorders: [ShortcutRecorderView] = []
    /// Only customized actions have one.
    private(set) var resetButton: NSButton?

    init(shortcuts: [KeyShortcut], actionTitle: String, isCustomized: Bool, maxCount: Int,
         passesThrough: @escaping (KeyShortcut) -> Bool) {
        self.shortcuts = shortcuts
        super.init(frame: .zero)

        recorders = shortcuts.enumerated().map { index, shortcut in
            let recorder = ShortcutRecorderView(shortcut: shortcut, actionTitle: actionTitle)
            recorder.onRecord = { [weak self] in self?.onRecord?($0, index) }
            recorder.onRemove = { [weak self] in self?.onRemove?(index) }
            return recorder
        }
        if shortcuts.count < maxCount {
            let add = ShortcutRecorderView(shortcut: nil, actionTitle: actionTitle)
            add.toolTip = "Add a shortcut"
            add.onRecord = { [weak self] in self?.onRecord?($0, nil) }
            recorders.append(add)
        }
        recorders.forEach { $0.passesThrough = passesThrough }

        let stack = NSStackView(views: recorders)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        guard isCustomized else { return }
        let reset = NSButton.symbol("arrow.counterclockwise", target: self, action: #selector(reset(_:)))
        reset.setAccessibilityLabel("Restore default shortcuts for \(actionTitle)")
        reset.contentTintColor = .secondaryLabelColor
        reset.toolTip = "Restore default"
        reset.translatesAutoresizingMaskIntoConstraints = false
        addSubview(reset)
        resetButton = reset
        NSLayoutConstraint.activate([
            reset.leadingAnchor.constraint(greaterThanOrEqualTo: stack.trailingAnchor, constant: 8),
            reset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            reset.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func reset(_ sender: Any?) { onReset?() }

    /// The recorder at `index`, clamped to the last one (the add recorder, if
    /// any). Never empty: with no shortcuts there is always the add recorder.
    func recorder(at index: Int) -> NSView {
        recorders[min(max(index, 0), recorders.count - 1)]
    }

    /// Position of the recorder that is or contains `view`, if any.
    func recorderIndex(containing view: NSView) -> Int? {
        recorders.firstIndex { view.isDescendant(of: $0) }
    }
}
