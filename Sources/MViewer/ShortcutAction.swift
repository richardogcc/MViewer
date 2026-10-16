import AppKit

/// Every action whose keyboard shortcuts can be customized in Settings.
/// Raw values are the keys custom shortcuts are saved under: don't rename.
enum ShortcutAction: String, CaseIterable {
    case previousFile, nextFile, playPause
    case toggleFullScreen, zoomToFit, actualSize, zoomIn, zoomOut, toggle360, getInfo
    case openFile, copyImage, showInFinder, moveToTrash
    case showShortcuts, showAbout, exitOrClose

    enum Category: CaseIterable {
        case navigation, view, file, general

        var title: String {
            switch self {
            case .navigation: return "Navigation"
            case .view: return "View"
            case .file: return "File"
            case .general: return "General"
            }
        }

        var actions: [ShortcutAction] {
            ShortcutAction.allCases.filter { $0.category == self }
        }
    }

    var category: Category {
        switch self {
        case .previousFile, .nextFile, .playPause: return .navigation
        case .toggleFullScreen, .zoomToFit, .actualSize, .zoomIn, .zoomOut, .toggle360, .getInfo:
            return .view
        case .openFile, .copyImage, .showInFinder, .moveToTrash: return .file
        case .showShortcuts, .showAbout, .exitOrClose: return .general
        }
    }

    var title: String {
        switch self {
        case .previousFile: return "Previous file"
        case .nextFile: return "Next file"
        case .playPause: return "Play / pause video (next file for images)"
        case .toggleFullScreen: return "Full screen"
        case .zoomToFit: return "Zoom to fit"
        case .actualSize: return "Actual size (pixel-perfect)"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .toggle360: return "Toggle 360° video view"
        case .getInfo: return "Info sidebar"
        case .openFile: return "Open…"
        case .copyImage: return "Copy image"
        case .showInFinder: return "Show in Finder"
        case .moveToTrash: return "Move to Trash"
        case .showShortcuts: return "Keyboard shortcuts help"
        case .showAbout: return "About / version"
        case .exitOrClose: return "Exit full screen / close window"
        }
    }

    /// The first default with a modifier is the one shown in the menu bar.
    var defaultShortcuts: [KeyShortcut] {
        switch self {
        case .previousFile: return [.left, .up]
        case .nextFile: return [.right, .down]
        case .playPause: return [.space]
        case .toggleFullScreen: return [KeyShortcut("f", [.control, .command]), KeyShortcut("f")]
        case .zoomToFit: return [KeyShortcut("0", .command), KeyShortcut("0")]
        case .actualSize: return [KeyShortcut("1", .command), KeyShortcut("1")]
        case .zoomIn: return [KeyShortcut("+", .command), KeyShortcut("=", .command)]
        case .zoomOut: return [KeyShortcut("-", .command)]
        case .toggle360: return [KeyShortcut("3")]
        case .getInfo: return [KeyShortcut("i", .command)]
        case .openFile: return [KeyShortcut("o", .command)]
        case .copyImage: return [KeyShortcut("c", .command)]
        case .showInFinder: return []
        case .moveToTrash: return [KeyShortcut.delete.with(.command)]
        case .showShortcuts: return [KeyShortcut("/", .command), KeyShortcut("h"), KeyShortcut("?")]
        case .showAbout: return [KeyShortcut("a")]
        case .exitOrClose: return [.escape]
        }
    }
}
