import AppKit

/// A key plus modifier flags. `key` is the character the key types on the
/// current keyboard layout (lowercased), or a name for non-printing keys
/// ("left", "space"…), so bindings follow the layout like menu key equivalents.
struct KeyShortcut: Codable, Hashable {
    let key: String
    let modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    /// Nil when the event has no usable key (bare modifiers, dead keys…).
    init?(event: NSEvent) {
        var flags = event.modifierFlags.intersection(Self.relevantModifiers)
        if let special = Self.specialKeys[event.keyCode] {
            self.init(special.name, flags)
            return
        }
        // Globe/fn with a letter, number or symbol key is left to the system
        // (🌐⌃F tiles the window…): not recordable, never matched. Special keys
        // above don't get here; arrows, F-keys and the like always carry fn.
        if event.modifierFlags.contains(.function) { return nil }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              chars.count == 1, let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        // Shift already shaped a non-letter ("?" is ⇧/), so it isn't part of the binding.
        if flags.contains(.shift), chars.uppercased() == chars {
            flags.remove(.shift)
        }
        self.init(chars, flags)
    }

    /// The same key with other modifiers: `KeyShortcut.delete.with(.command)`.
    func with(_ modifiers: NSEvent.ModifierFlags) -> KeyShortcut {
        KeyShortcut(key, modifiers)
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Has ⌘, ⌃ or ⌥: as a menu key equivalent it works from any window.
    var hasNonShiftModifier: Bool {
        !modifierFlags.isDisjoint(with: [.command, .control, .option])
    }

    /// Same form `init?(event:)` produces: lowercased character, masked modifiers.
    var normalized: KeyShortcut {
        KeyShortcut(Self.specialKey(named: key) == nil ? key.lowercased() : key, modifierFlags)
    }

    var displayString: String {
        let flags = modifierFlags
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + (Self.specialKey(named: key)?.display ?? key.uppercased())
    }

    var menuKeyEquivalent: String {
        Self.specialKey(named: key)?.menu ?? key
    }
}

// MARK: - Non-printing keys

extension KeyShortcut {
    // The key strings ("left", "return"…, and "f1"–"f19" below) are what
    // UserDefaults stores for custom shortcuts: never change them, or saved
    // shortcuts stop matching. The Swift constant names can change freely.
    static let left = KeyShortcut("left")
    static let right = KeyShortcut("right")
    static let down = KeyShortcut("down")
    static let up = KeyShortcut("up")
    static let space = KeyShortcut("space")
    static let escape = KeyShortcut("escape")
    static let delete = KeyShortcut("delete")
    static let forwardDelete = KeyShortcut("forwardDelete")
    static let returnKey = KeyShortcut("return")
    static let enter = KeyShortcut("enter")
    static let tab = KeyShortcut("tab")
    static let home = KeyShortcut("home")
    static let end = KeyShortcut("end")
    static let pageUp = KeyShortcut("pageUp")
    static let pageDown = KeyShortcut("pageDown")
    static let help = KeyShortcut("help")
    static let clear = KeyShortcut("clear")

    private struct SpecialKey {
        let name: String
        let display: String
        let menu: String

        init(_ shortcut: KeyShortcut, display: String, menu: String) {
            self.init(name: shortcut.key, display: display, menu: menu)
        }

        init(name: String, display: String, menu: String) {
            self.name = name
            self.display = display
            self.menu = menu
        }
    }

    private static func function(_ code: Int) -> String { String(UnicodeScalar(code)!) }

    /// By virtual key code, which is the same on every layout for these keys.
    private static let specialKeys: [UInt16: SpecialKey] = {
        var keys: [UInt16: SpecialKey] = [
            123: SpecialKey(left, display: "←", menu: function(NSLeftArrowFunctionKey)),
            124: SpecialKey(right, display: "→", menu: function(NSRightArrowFunctionKey)),
            125: SpecialKey(down, display: "↓", menu: function(NSDownArrowFunctionKey)),
            126: SpecialKey(up, display: "↑", menu: function(NSUpArrowFunctionKey)),
            49: SpecialKey(space, display: "Space", menu: " "),
            53: SpecialKey(escape, display: "Esc", menu: "\u{1b}"),
            51: SpecialKey(delete, display: "⌫", menu: "\u{8}"),
            117: SpecialKey(forwardDelete, display: "⌦", menu: function(NSDeleteFunctionKey)),
            36: SpecialKey(returnKey, display: "↩", menu: "\r"),
            76: SpecialKey(enter, display: "⌤", menu: "\u{3}"),
            48: SpecialKey(tab, display: "⇥", menu: "\t"),
            115: SpecialKey(home, display: "↖", menu: function(NSHomeFunctionKey)),
            119: SpecialKey(end, display: "↘", menu: function(NSEndFunctionKey)),
            116: SpecialKey(pageUp, display: "⇞", menu: function(NSPageUpFunctionKey)),
            121: SpecialKey(pageDown, display: "⇟", menu: function(NSPageDownFunctionKey)),
            114: SpecialKey(help, display: "Help", menu: function(NSHelpFunctionKey)),
            71: SpecialKey(clear, display: "⌧", menu: function(NSClearLineFunctionKey)),
        ]
        // F1–F19; their NSF…FunctionKey constants are consecutive.
        let fKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                   105, 107, 113, 106, 64, 79, 80]
        for (index, code) in fKeyCodes.enumerated() {
            keys[code] = SpecialKey(name: "f\(index + 1)", display: "F\(index + 1)",
                                    menu: function(NSF1FunctionKey + index))
        }
        return keys
    }()

    private static let specialKeysByName: [String: SpecialKey] =
        Dictionary(uniqueKeysWithValues: specialKeys.values.map { ($0.name, $0) })

    private static func specialKey(named name: String) -> SpecialKey? { specialKeysByName[name] }
}
