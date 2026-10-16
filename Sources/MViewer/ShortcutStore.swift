import AppKit

/// Current shortcut bindings. Only customized actions are persisted, so
/// untouched actions pick up new defaults in later versions.
final class ShortcutStore {
    static let shared = ShortcutStore(defaults: .standard, notificationCenter: .default)
    static let didChange = Notification.Name("ShortcutStoreDidChange")
    static let maxShortcutsPerAction = 4

    private static let defaultsKey = "KeyboardShortcuts"

    /// Standard app/window shortcuts that stay owned by the menu bar.
    private static let reserved: Set<KeyShortcut> = [
        KeyShortcut("q", .command), KeyShortcut("h", .command), KeyShortcut("h", [.option, .command]),
        KeyShortcut("w", .command), KeyShortcut("m", .command), KeyShortcut(",", .command),
    ]

    /// Where `didChange` is posted (with the store as object).
    let notificationCenter: NotificationCenter
    private let defaults: UserDefaults
    private var bindings: [ShortcutAction: [KeyShortcut]] = [:]

    /// Decodes one saved shortcut, so a bad entry doesn't discard the rest.
    private struct LossyShortcut: Decodable {
        let value: KeyShortcut?

        init(from decoder: Decoder) throws {
            value = try? KeyShortcut(from: decoder)
        }
    }

    /// Use `shared`; a second store on the same defaults would drift from it.
    /// Other instances are for isolated defaults (tests).
    init(defaults: UserDefaults, notificationCenter: NotificationCenter) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        var saved: [String: [LossyShortcut]] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [LossyShortcut]].self, from: data) {
            saved = decoded
        }

        // Customized actions claim their shortcuts first, so a default added in
        // a later version never duplicates a shortcut the user picked.
        var claimed = Set<KeyShortcut>()
        for action in ShortcutAction.allCases {
            guard let entries = saved[action.rawValue] else { continue }
            let valid = entries.compactMap { $0.value?.normalized }
                .filter { !$0.key.isEmpty && !Self.reserved.contains($0) }
                .uniqued()
                .prefix(Self.maxShortcutsPerAction)
            let list = valid.filter { claimed.insert($0).inserted }
            // A saved list with nothing usable left falls back to the defaults;
            // an empty one means the user removed every shortcut.
            if list.isEmpty && !entries.isEmpty { continue }
            set(list, for: action)
        }
        for action in ShortcutAction.allCases where bindings[action] == nil {
            bindings[action] = action.defaultShortcuts.filter { claimed.insert($0).inserted }
        }
    }

    func shortcuts(for action: ShortcutAction) -> [KeyShortcut] {
        bindings[action] ?? []
    }

    /// Order-insensitive in effect: a list with exactly the default shortcuts
    /// is always stored in default order (see `set(_:for:)`).
    func isDefault(_ action: ShortcutAction) -> Bool {
        shortcuts(for: action) == action.defaultShortcuts
    }

    func isReserved(_ shortcut: KeyShortcut) -> Bool {
        Self.reserved.contains(shortcut)
    }

    /// Exact match first; otherwise Shift alone is ignored, so ⇧← still goes
    /// back unless ⇧← has a binding of its own.
    func action(matching shortcut: KeyShortcut) -> ShortcutAction? {
        if let action = owner(of: shortcut) { return action }
        guard shortcut.modifierFlags == .shift else { return nil }
        return owner(of: shortcut.with([]))
    }

    func action(matching event: NSEvent) -> ShortcutAction? {
        KeyShortcut(event: event).flatMap { action(matching: $0) }
    }

    /// Binds `shortcut` to `action`, replacing the shortcut at `index` or
    /// appending. A shortcut belongs to one action only: returns the action it
    /// was taken from, if any.
    @discardableResult
    func assign(_ shortcut: KeyShortcut, to action: ShortcutAction,
                replacing index: Int? = nil) -> ShortcutAction? {
        let previousOwner = takeAway([shortcut], except: action).first
        var list = shortcuts(for: action)
        if let index, list.indices.contains(index) {
            list[index] = shortcut
        } else {
            list.append(shortcut)
        }
        set(list.uniqued(), for: action)
        commit()
        return previousOwner
    }

    func remove(at index: Int, from action: ShortcutAction) {
        guard var list = bindings[action], list.indices.contains(index) else { return }
        list.remove(at: index)
        set(list, for: action)
        commit()
    }

    /// Restores the action's defaults, taking them from other actions;
    /// returns the actions they were taken from.
    @discardableResult
    func reset(_ action: ShortcutAction) -> [ShortcutAction] {
        let touched = takeAway(action.defaultShortcuts, except: action)
        bindings[action] = action.defaultShortcuts
        commit()
        return touched
    }

    func resetAll() {
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultShortcuts
        }
        commit()
    }

    /// Stores `list`, putting it back in default order when it holds exactly
    /// the default shortcuts: removing a default and adding it back restores
    /// the default menu shortcut, and the action counts as untouched again.
    private func set(_ list: [KeyShortcut], for action: ShortcutAction) {
        let defaults = action.defaultShortcuts
        bindings[action] = Set(list) == Set(defaults) ? defaults : list
    }

    private func owner(of shortcut: KeyShortcut) -> ShortcutAction? {
        ShortcutAction.allCases.first { shortcuts(for: $0).contains(shortcut) }
    }

    /// Removes `shortcuts` from every action but `keeper`; returns the actions touched.
    @discardableResult
    private func takeAway(_ shortcuts: [KeyShortcut], except keeper: ShortcutAction) -> [ShortcutAction] {
        var touched: [ShortcutAction] = []
        for other in ShortcutAction.allCases where other != keeper {
            let list = self.shortcuts(for: other)
            let kept = list.filter { !shortcuts.contains($0) }
            if kept.count != list.count {
                set(kept, for: other)
                touched.append(other)
            }
        }
        return touched
    }

    private func commit() {
        var custom: [String: [KeyShortcut]] = [:]
        for action in ShortcutAction.allCases where !isDefault(action) {
            custom[action.rawValue] = shortcuts(for: action)
        }
        if custom.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        notificationCenter.post(name: Self.didChange, object: self)
    }
}

extension NSMenuItem {
    /// Shows the action's first shortcut that works from any window, else its
    /// first shortcut, or none. Pass `allowsPlainKey: false` for items enabled
    /// in every window (e.g. Open…): menu key equivalents come before keyDown,
    /// so a plain key bound there (Space, Delete…) would fire the item instead
    /// of reaching a focused shortcut recorder in Settings.
    func applyShortcut(of action: ShortcutAction, from store: ShortcutStore = .shared,
                       allowsPlainKey: Bool = true) {
        let shortcuts = store.shortcuts(for: action)
        let plain = allowsPlainKey ? shortcuts.first : nil
        if let shortcut = shortcuts.first(where: \.hasNonShiftModifier) ?? plain {
            keyEquivalent = shortcut.menuKeyEquivalent
            keyEquivalentModifierMask = shortcut.modifierFlags
        } else {
            keyEquivalent = ""
            keyEquivalentModifierMask = []
        }
    }
}

private extension Sequence where Element: Hashable {
    /// The elements in order, without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
