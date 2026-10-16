import AppKit
import AVKit
import ImageIO

final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTitle: "Copy Image")?.title = currentKind == .video ? "Copy File" : "Copy Image"
        menu.item(withTitle: "Copy File")?.title = currentKind == .video ? "Copy File" : "Copy Image"
    }

    private var navigator: FileNavigator?
    private var currentURL: URL?
    private var currentKind: Media.Kind = .image
    private var generation = 0

    private let mediaContainer = NSView()
    private let scrollView = ZoomScrollView()
    private let docView = ImageDocumentView()
    private let infoSidebar = InfoSidebarView()
    private let sidebarHandle = SidebarResizeHandle()
    private var sidebarVisible = false
    private var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "InfoSidebarWidth")
        return saved >= 200 ? CGFloat(saved) : 320
    }()
    private let counterPill = CounterPillView()
    private let shortcutsOverlay = ShortcutsOverlayView()
    private let aboutOverlay = AboutOverlayView()
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var sphericalView: SphericalVideoView?
    private let playerControls = PlayerControlsBar()
    private var is360 = false
    private var sphericalCache: [URL: Bool] = [:]
    private var volumeObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var animator: FrameAnimator?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var hideControlsTimer: Timer?

    private static let volumeKey = "VideoVolume"
    private static let mutedKey = "VideoMuted"

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var actualSizeMagnification: CGFloat { 1 / backingScale }

    /// Preview decode budget: enough pixels for any screen attached.
    private var previewMaxPixel: CGFloat {
        let screens = NSScreen.screens
        let px = screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3456
        return max(px, 2048)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        window.title = "MViewer"
        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }

        super.init(window: window)
        window.delegate = self

        let container = DropContainerView(frame: window.contentLayoutRect)
        container.autoresizingMask = [.width, .height]
        container.onDrop = { [weak self] urls in self?.open(urls: urls) }
        window.contentView = container

        mediaContainer.frame = container.bounds
        mediaContainer.autoresizingMask = [.width, .height]
        container.addSubview(mediaContainer)

        infoSidebar.frame = NSRect(x: container.bounds.width - sidebarWidth, y: 0,
                                   width: sidebarWidth, height: container.bounds.height)
        infoSidebar.autoresizingMask = [.height, .minXMargin]
        infoSidebar.isHidden = true
        container.addSubview(infoSidebar)

        scrollView.frame = mediaContainer.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = docView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 50
        scrollView.drawsBackground = true
        scrollView.backgroundColor = window.backgroundColor ?? .black
        mediaContainer.addSubview(scrollView)

        counterPill.isHidden = true
        mediaContainer.addSubview(counterPill)

        playerControls.isHidden = true
        playerControls.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        mediaContainer.addSubview(playerControls)

        infoSidebar.onClose = { [weak self] in self?.getInfo(nil) }

        sidebarHandle.isHidden = true
        sidebarHandle.autoresizingMask = [.height, .minXMargin]
        sidebarHandle.onDrag = { [weak self] x in
            guard let self, let container = self.window?.contentView else { return }
            let width = container.bounds.width - x
            self.sidebarWidth = min(max(width, 200), container.bounds.width * 0.6)
            UserDefaults.standard.set(Double(self.sidebarWidth), forKey: "InfoSidebarWidth")
            self.layoutContent()
            if self.currentKind == .image { self.fitToWindow() }
        }
        container.addSubview(sidebarHandle)

        shortcutsOverlay.frame = container.bounds
        shortcutsOverlay.autoresizingMask = [.width, .height]
        shortcutsOverlay.isHidden = true
        shortcutsOverlay.onDismiss = { [weak self] in self?.setShortcutsVisible(false) }
        container.addSubview(shortcutsOverlay)

        aboutOverlay.frame = container.bounds
        aboutOverlay.autoresizingMask = [.width, .height]
        aboutOverlay.isHidden = true
        aboutOverlay.onDismiss = { [weak self] in self?.aboutOverlay.isHidden = true }
        container.addSubview(aboutOverlay)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleClick.numberOfClicksRequired = 2
        docView.addGestureRecognizer(doubleClick)

        let contextMenu = makeContextMenu()
        container.menu = contextMenu
        docView.menu = contextMenu

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }

        window.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            if let self, event.window === self.window {
                self.showTransientControls()
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        hideControlsTimer?.invalidate()
    }

    // MARK: - Transient controls (QuickTime-style auto-hide)

    private func showTransientControls() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            counterPill.animator().alphaValue = 1
            playerControls.animator().alphaValue = 1
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.hideTransientControls()
        }
    }

    private func hideTransientControls() {
        guard let window else { return }
        // Keep the bar up while the pointer hovers over it, like QuickTime.
        let point = mediaContainer.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !playerControls.isHidden, playerControls.frame.contains(point) {
            scheduleControlsHide()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            counterPill.animator().alphaValue = 0
            playerControls.animator().alphaValue = 0
        }
    }

    // MARK: - Opening

    func open(urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1, first.hasDirectoryPath {
            navigator = FileNavigator(directory: first)
        } else if urls.count > 1 {
            navigator = FileNavigator(list: urls)
        } else {
            navigator = FileNavigator(url: first)
        }
        guard let url = navigator?.current else {
            presentError(message: "No viewable files found in \(first.lastPathComponent)")
            return
        }
        display(url)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Display

    private func display(_ url: URL) {
        generation += 1
        animator?.stop()
        animator = nil
        currentURL = url
        updateTitle()

        guard let kind = Media.kind(of: url) else {
            presentError(message: "Unsupported file: \(url.lastPathComponent)")
            return
        }
        currentKind = kind

        switch kind {
        case .video: showVideo(url)
        case .image: showImage(url)
        }

        if sidebarVisible {
            infoSidebar.render(url: url)
        }
        showTransientControls()
        prefetchNeighbors()
    }

    private func showImage(_ url: URL) {
        let gen = generation
        teardownPlayer()
        scrollView.isHidden = false

        guard let source = MediaLoader.source(for: url) else {
            presentError(message: "Could not read \(url.lastPathComponent)")
            return
        }

        let nativeSize = MediaLoader.pixelSize(of: source)
        let isAnimated = Media.isAnimatable(url) && CGImageSourceGetCount(source) > 1

        if isAnimated {
            let animator = FrameAnimator(source: source, layer: docView.contentLayer)
            let size = animator.canvasSize
            let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
            docView.setImage(first, pixelSize: size)
            self.animator = animator
            fitToWindow()
            animator.start()
            return
        }

        var displayedFull = false
        if let cachedFull = ImageCache.shared.full(for: url) {
            docView.setImage(cachedFull, pixelSize: nativeSize
                ?? CGSize(width: cachedFull.width, height: cachedFull.height))
            displayedFull = true
        } else {
            let preview = ImageCache.shared.preview(for: url)
                ?? MediaLoader.quickPreview(source: source, maxPixel: previewMaxPixel)
            if let preview {
                ImageCache.shared.setPreview(preview, for: url)
                let size = nativeSize ?? CGSize(width: preview.width, height: preview.height)
                docView.setImage(preview, pixelSize: size)
            } else {
                docView.setImage(nil, pixelSize: nativeSize ?? .zero)
            }
        }

        fitToWindow()

        // Swap in the full-resolution decode if the preview is smaller than needed.
        if !displayedFull {
            let needsFull: Bool
            if let nativeSize {
                let previewSide = CGFloat(ImageCache.shared.preview(for: url)
                    .map { max($0.width, $0.height) } ?? 0)
                needsFull = max(nativeSize.width, nativeSize.height) > previewSide + 1
            } else {
                needsFull = true
            }
            guard needsFull else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let full = MediaLoader.fullImage(url: url) else { return }
                ImageCache.shared.setFull(full, for: url)
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.docView.updateContents(full)
                }
            }
        }
    }

    private func showVideo(_ url: URL) {
        scrollView.isHidden = true
        // Silence the previous player synchronously: AVPlayer deallocates
        // lazily, so just replacing it leaves its audio running for a while.
        teardownPlayer()
        let player = AVPlayer(url: url)

        // Restore the last volume/mute the user set, and track future changes.
        let defaults = UserDefaults.standard
        player.volume = defaults.object(forKey: Self.volumeKey) as? Float ?? 1.0
        player.isMuted = defaults.bool(forKey: Self.mutedKey)
        volumeObservation = player.observe(\.volume, options: [.new]) { _, change in
            if let volume = change.newValue {
                UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.new]) { _, change in
            if let muted = change.newValue {
                UserDefaults.standard.set(muted, forKey: Self.mutedKey)
            }
        }

        if playerView == nil {
            let view = AVPlayerView(frame: mediaContainer.bounds)
            view.autoresizingMask = [.width, .height]
            view.controlsStyle = .floating
            view.videoGravity = .resizeAspect
            view.menu = docView.menu
            mediaContainer.addSubview(view, positioned: .below, relativeTo: counterPill)
            playerView = view
        }
        playerView?.isHidden = false
        playerView?.player = player
        self.player = player
        player.play()

        if let cached = sphericalCache[url] {
            if cached { enable360() }
        } else {
            let gen = generation
            Task { [weak self] in
                let spherical = await SphericalDetector.isSpherical(url: url,
                                                                    asset: AVURLAsset(url: url))
                await MainActor.run {
                    guard let self else { return }
                    self.sphericalCache[url] = spherical
                    if self.generation == gen, spherical { self.enable360() }
                }
            }
        }
    }

    private func enable360() {
        guard currentKind == .video, let player, !is360 else { return }
        is360 = true
        playerView?.player = nil
        playerView?.isHidden = true
        if sphericalView == nil {
            let view = SphericalVideoView(frame: mediaContainer.bounds, options: nil)
            view.autoresizingMask = [.width, .height]
            view.menu = docView.menu
            mediaContainer.addSubview(view, positioned: .below, relativeTo: counterPill)
            sphericalView = view
        }
        let size = player.currentItem?.presentationSize ?? .zero
        sphericalView?.configure(player: player,
                                 videoSize: size.width > 0 ? size
                                     : CGSize(width: 3840, height: 1920))
        sphericalView?.isHidden = false
        playerControls.attach(player)
        playerControls.isHidden = false
        positionPlayerControls()
        updateTitle()
        showTransientControls()
    }

    private func positionPlayerControls() {
        playerControls.setFrameOrigin(NSPoint(
            x: (mediaContainer.bounds.width - PlayerControlsBar.barSize.width) / 2, y: 54))
    }

    private func disable360() {
        guard is360 else { return }
        is360 = false
        sphericalView?.teardown()
        sphericalView?.isHidden = true
        playerControls.detach()
        playerControls.isHidden = true
        if let player {
            playerView?.player = player
            playerView?.isHidden = false
        }
        updateTitle()
    }

    @objc func toggle360(_ sender: Any?) {
        guard currentKind == .video else { return }
        is360 ? disable360() : enable360()
    }

    private func teardownPlayer() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        muteObservation?.invalidate()
        muteObservation = nil
        sphericalView?.teardown()
        sphericalView?.isHidden = true
        playerControls.detach()
        playerControls.isHidden = true
        is360 = false
        let detached = player
        player = nil
        if playerView?.player == nil, let detached {
            // 360 mode had taken the player off the AVPlayerView; silence it here.
            detached.pause()
            detached.replaceCurrentItem(with: nil)
        }
        guard let old = playerView?.player else {
            playerView?.isHidden = true
            return
        }
        old.pause()
        old.replaceCurrentItem(with: nil)
        playerView?.player = nil
        playerView?.isHidden = true
    }

    private func prefetchNeighbors() {
        guard let navigator else { return }
        let maxPixel = previewMaxPixel
        for url in [navigator.peekNext(), navigator.peekPrevious()].compactMap({ $0 }) {
            ImageCache.shared.prefetchPreview(for: url, maxPixel: maxPixel)
        }
    }

    // MARK: - Window & zoom

    @objc func zoomToFit(_ sender: Any?) { fitToWindow() }

    private func fitToWindow() {
        let doc = docView.frame.size
        guard doc.width > 1, doc.height > 1 else { return }
        let available = scrollView.bounds.size
        guard available.width > 0, available.height > 0 else { return }
        let fit = min(available.width / doc.width, available.height / doc.height)
        scrollView.magnification = fit
    }

    @objc func actualSize(_ sender: Any?) {
        setMagnificationCentered(actualSizeMagnification)
    }

    @objc func zoomIn(_ sender: Any?) {
        setMagnificationCentered(scrollView.magnification * 1.3)
    }

    @objc func zoomOut(_ sender: Any?) {
        setMagnificationCentered(scrollView.magnification / 1.3)
    }

    private func setMagnificationCentered(_ magnification: CGFloat) {
        let visible = scrollView.contentView.bounds
        let center = CGPoint(x: visible.midX, y: visible.midY)
        scrollView.setMagnification(magnification, centeredAt: center)
    }

    @objc private func toggleZoom() {
        let fitMag: CGFloat = {
            let doc = docView.frame.size
            guard doc.width > 1 else { return actualSizeMagnification }
            let available = scrollView.bounds.size
            return min(available.width / doc.width, available.height / doc.height)
        }()
        if abs(scrollView.magnification - fitMag) < 0.001 {
            actualSize(nil)
        } else {
            fitToWindow()
        }
    }

    func windowDidResize(_ notification: Notification) {
        if currentKind == .image { fitToWindow() }
        positionPill()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        if currentKind == .image { fitToWindow() }
    }

    // MARK: - Navigation

    @objc func nextFile(_ sender: Any?) {
        guard var nav = navigator, nav.count > 1, let url = nav.next() else { return }
        navigator = nav
        display(url)
    }

    @objc func previousFile(_ sender: Any?) {
        guard var nav = navigator, nav.count > 1, let url = nav.previous() else { return }
        navigator = nav
        display(url)
    }

    // MARK: - Context menu & file actions

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Show in Finder",
                     action: #selector(showInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Image",
                     action: #selector(copyImage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Get Info",
                     action: #selector(getInfo(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash",
                     action: #selector(moveToTrash(_:)), keyEquivalent: "")
        return menu
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the file URL plus (for images) PNG/TIFF bitmap flavors, so both
    /// Finder and image editors can paste it.
    @objc func copyImage(_ sender: Any?) {
        guard let url = currentURL else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)

        if currentKind == .image {
            let cgImage = ImageCache.shared.full(for: url)
                ?? ImageCache.shared.preview(for: url)
                ?? MediaLoader.fullImage(url: url)
            if let cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let png = rep.representation(using: .png, properties: [:]) {
                    item.setData(png, forType: .png)
                }
                if let tiff = rep.representation(using: .tiff, properties: [:]) {
                    item.setData(tiff, forType: .tiff)
                }
            }
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    @objc func getInfo(_ sender: Any?) {
        sidebarVisible.toggle()
        layoutContent()
        if sidebarVisible, let url = currentURL {
            infoSidebar.render(url: url)
        }
        if currentKind == .image { fitToWindow() }
    }

    private func layoutContent() {
        guard let container = window?.contentView else { return }
        let bounds = container.bounds
        if sidebarVisible {
            let width = min(sidebarWidth, bounds.width / 2)
            mediaContainer.frame = NSRect(x: 0, y: 0,
                                          width: bounds.width - width, height: bounds.height)
            infoSidebar.frame = NSRect(x: bounds.width - width, y: 0,
                                       width: width, height: bounds.height)
            infoSidebar.isHidden = false
            sidebarHandle.frame = NSRect(x: infoSidebar.frame.minX - 6, y: 0,
                                         width: 12, height: bounds.height)
            sidebarHandle.isHidden = false
            container.window?.invalidateCursorRects(for: sidebarHandle)
        } else {
            infoSidebar.isHidden = true
            sidebarHandle.isHidden = true
            mediaContainer.frame = bounds
        }
        positionPill()
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let url = currentURL, var nav = navigator else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            presentError(message: "Could not move to Trash: \(error.localizedDescription)")
            return
        }
        let next = nav.removeCurrent()
        navigator = nav
        if let next {
            display(next)
        } else {
            window?.close()
        }
    }

    // MARK: - Keyboard

    @objc func showShortcuts(_ sender: Any?) {
        setShortcutsVisible(shortcutsOverlay.isHidden)
    }

    @objc func showAbout(_ sender: Any?) {
        shortcutsOverlay.isHidden = true
        aboutOverlay.isHidden.toggle()
        if !aboutOverlay.isHidden {
            aboutOverlay.needsLayout = true
        }
    }

    private func setShortcutsVisible(_ visible: Bool) {
        shortcutsOverlay.isHidden = !visible
        if visible {
            shortcutsOverlay.reload()
            shortcutsOverlay.needsLayout = true
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let action = ShortcutStore.shared.action(matching: event)
        // A held key repeats only actions meant to repeat (browsing, zooming).
        // Other repeats are swallowed, not passed on: the menu would run them
        // again (holding ⌘⌫ trashed one more file per repeat).
        if event.isARepeat, let action, !isRepeatable(action) { return true }
        if !shortcutsOverlay.isHidden || !aboutOverlay.isHidden {
            var reopening: [ShortcutAction] = []
            if !shortcutsOverlay.isHidden { reopening.append(.showShortcuts) }
            if !aboutOverlay.isHidden { reopening.append(.showAbout) }
            setShortcutsVisible(false)
            aboutOverlay.isHidden = true
            // Plain keys only dismiss. ⌘/⌃/⌥ combos also do their job (⌘, opens
            // Settings, ⌘Q quits…), except one that would reopen the overlay
            // being closed.
            let modified = !event.modifierFlags.isDisjoint(with: [.command, .control, .option])
            guard modified, !(action.map(reopening.contains) ?? false) else { return true }
        }
        guard let action else { return false }
        perform(action)
        return true
    }

    private func isRepeatable(_ action: ShortcutAction) -> Bool {
        switch action {
        case .previousFile, .nextFile, .zoomIn, .zoomOut: return true
        case .playPause: return currentKind == .image // Space browses images
        default: return false
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .previousFile: previousFile(nil)
        case .nextFile: nextFile(nil)
        case .playPause:
            if currentKind == .video, let player {
                player.rate == 0 ? player.play() : player.pause()
                showTransientControls()
            } else {
                nextFile(nil)
            }
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .zoomToFit: fitToWindow()
        case .actualSize: actualSize(nil)
        case .zoomIn: zoomIn(nil)
        case .zoomOut: zoomOut(nil)
        case .toggle360: toggle360(nil)
        case .getInfo: getInfo(nil)
        case .openFile: NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: self)
        case .copyImage: copyImage(nil)
        case .showInFinder: showInFinder(nil)
        case .moveToTrash: moveToTrash(nil)
        case .showShortcuts: setShortcutsVisible(true)
        case .showAbout: showAbout(nil)
        case .exitOrClose:
            if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                window?.close()
            }
        }
    }

    // MARK: - Misc

    private func updateTitle() {
        guard let url = currentURL else { return }
        window?.representedURL = url
        var title = url.lastPathComponent
        if is360 { title += "  ·  360°" }
        if let navigator, navigator.count > 1 {
            title += "  —  \(navigator.position)/\(navigator.count)"
        }
        window?.title = title
        if let navigator {
            counterPill.setText("\(navigator.position) / \(navigator.count)")
            counterPill.isHidden = false
            positionPill()
        } else {
            counterPill.isHidden = true
        }
    }

    private func positionPill() {
        counterPill.setFrameOrigin(NSPoint(
            x: (mediaContainer.bounds.width - counterPill.frame.width) / 2, y: 16))
    }

    private func presentError(message: String) {
        window?.title = message
    }
}
