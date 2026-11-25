import AppKit
import SwiftUI
import Combine

/// The menu bar icon. Click it for the Ferry menu; drop files or folders on it to send them.
///
/// The menu is a floating panel placed under the icon, not an NSPopover. A popover is anchored
/// to the menu bar, so it closes whenever the menu bar hides (in full-screen apps, as soon as the
/// pointer moves away from the top of the screen). The panel stays until you click elsewhere,
/// press Esc, or click the icon again.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: MenuPanel
    private let host: NSHostingView<MenuContentView>
    /// Off-screen copy of the menu, used only to measure how big the panel should be.
    private let measurer: NSHostingController<MenuContentView>
    private var busySubscription: AnyCancellable?
    private var sizeSubscription: AnyCancellable?
    private var monitors: [Any] = []

    init(model: AppModel) {
        self.model = model
        host = NSHostingView(rootView: MenuContentView(model: model))
        // Size by measuring, never by SwiftUI's automatic sizing: on this macOS that sizing can
        // loop inside AppKit's layout pass and abort the app (the crash behind the first version).
        host.sizingOptions = []
        measurer = NSHostingController(rootView: MenuContentView(model: model))
        panel = MenuPanel(content: host)
        super.init()

        sizeSubscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPanel() }
        }
        // Opening one of Ferry's windows (or a file chooser) from the menu closes the menu.
        model.windows.onWillShow = { [weak self] in self?.closePanel() }

        guard let button = item.button else { return }
        setIcon(busy: false)
        let overlay = StatusButtonOverlay(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.togglePopover() }
        overlay.onDragHover = { [weak button] hovering in button?.highlight(hovering) }
        overlay.onDrop = { [weak self] urls in
            self?.closePanel()
            self?.model.beginSend(urls)
        }
        button.addSubview(overlay)
        button.toolTip = "Ferry: click to open, or drop files here to send them to your phone"

        busySubscription = model.$transfers
            .map { $0.contains { !$0.phase.isTerminal && $0.phase != .awaitingYourAccept } }
            .removeDuplicates()
            .sink { [weak self] busy in self?.setIcon(busy: busy) }
    }

    private func setIcon(busy: Bool) {
        let image = NSImage(systemSymbolName: busy ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle",
                            accessibilityDescription: "Ferry")
        image?.isTemplate = true
        item.button?.image = image
    }

    private func contentSize() -> NSSize {
        measurer.rootView = MenuContentView(model: model)
        let size = measurer.sizeThatFits(in: NSSize(width: 360, height: 4000))
        return NSSize(width: ceil(max(size.width, 360)), height: ceil(max(size.height, 100)))
    }

    /// Resize to the content, keeping the top edge (just under the icon) in place.
    private func fitPanel() {
        guard panel.isVisible else { return }
        let size = contentSize()
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    func togglePopover() {
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = contentSize()
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Just under the menu bar, centred on the icon. (Right after launch the icon may not be
        // placed yet; then use the top-right corner.)
        let iconPlaced = iconRect.width > 0 && screen.frame.contains(NSPoint(x: iconRect.midX, y: iconRect.midY))
            && iconRect.minY >= visible.maxY - 4
        var x = iconPlaced ? iconRect.midX - size.width / 2 : visible.maxX - size.width - 10
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let y = (iconPlaced ? min(iconRect.minY, visible.maxY) : visible.maxY) - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)

        // Close on a click anywhere outside the menu (other apps, or Ferry's other windows), or Esc.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closePanel(); return nil } // Esc
                    return event
                }
                // Clicks on the icon are handled by its own toggle.
                if event.window !== self.panel && event.window !== self.item.button?.window { self.closePanel() }
                return event
            }
        } as Any)
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

/// A borderless, non-activating floating panel with the system's popover material.
final class MenuPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        contentView = background
    }

    override var canBecomeKey: Bool { true }
}

/// Sits on top of the status bar button so it can take file drops, which the button itself can't.
final class StatusButtonOverlay: NSView {
    var onClick: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onDragHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragHover?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHover?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// Ordinary titled windows hosting SwiftUI views, one per key. Windows are sized by measuring
/// the SwiftUI content and resized (outside the layout pass) whenever the model changes.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]
    private var resizers: [String: AnyCancellable] = [:]
    weak var model: AppModel?
    /// Called before any window opens (the menu closes itself).
    var onWillShow: (() -> Void)?

    func show<Content: View>(_ key: String, title: String, floating: Bool = false, resizable: Bool = false,
                             size: NSSize? = nil, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        onWillShow?()
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        let initial = size ?? host.fittingSize
        let style: NSWindow.StyleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial), styleMask: style, backing: .buffered, defer: false)
        window.contentView = host
        window.title = title
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        if floating { window.level = .floating }
        if resizable { window.contentMinSize = initial }
        window.center()
        windows[key] = window
        if let onClose { closeHandlers[key] = onClose }
        if !resizable, let model {
            resizers[key] = model.objectWillChange.sink { [weak window, weak host] _ in
                DispatchQueue.main.async {
                    guard let window, let host else { return }
                    let fitting = host.fittingSize
                    let current = window.contentRect(forFrameRect: window.frame).size
                    guard abs(fitting.height - current.height) > 0.5 || abs(fitting.width - current.width) > 0.5 else { return }
                    // Keep the top edge where it is while the height changes.
                    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: fitting))
                    frame.origin.x = window.frame.minX
                    frame.origin.y = window.frame.maxY - frame.height
                    window.setFrame(frame, display: true, animate: false)
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func isShowing(_ key: String) -> Bool { windows[key] != nil }

    func close(_ key: String) {
        windows[key]?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let window = notification.object as? NSWindow, let key = window.identifier?.rawValue else { return }
            windows[key] = nil
            resizers[key] = nil
            closeHandlers.removeValue(forKey: key)?()
        }
    }
}
