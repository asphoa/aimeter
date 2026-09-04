import AppKit
import SwiftUI

/// The floating card panel that replaces the NSMenu dropdown for
/// `menuBar.panel == "cards"` (the default, v1.0.27). This file owns only the
/// window mechanics - anchoring, materials, dismissal; the content is
/// `PanelView`, driven by the `PanelState` this controller publishes.
@MainActor
final class CardPanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private var panel: FloatingCardPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(from button: NSStatusBarButton) {
        if isVisible { close() } else { show(from: button) }
    }

    /// Anchored under the status item's own button frame, right-aligned to
    /// it, 8pt below the menu bar. 372pt wide; height from content, capped at
    /// 720 by `PanelView`'s own `.frame(maxHeight:)` - past that it scrolls
    /// internally, so this only ever asks for what SwiftUI already fitted.
    func show(from button: NSStatusBarButton) {
        let width: CGFloat = 372
        let hosting = NSHostingView(rootView: PanelView(state: state, requestClose: { [weak self] in
            self?.close()
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let p = panel ?? makePanel()
        p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        p.contentView?.addSubview(hosting)
        if let cv = p.contentView {
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: cv.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: cv.bottomAnchor)
            ])
        }
        panel = p

        let fitted = hosting.fittingSize
        let height = max(80, min(fitted.height, 720))
        let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? NSRect(x: 0, y: NSScreen.main?.frame.maxY ?? 800, width: 0, height: 0)
        let x = buttonFrame.maxX - width
        let y = buttonFrame.minY - 8 - height
        p.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        p.makeKeyAndOrderFront(nil)
        installMonitors(button: button)
    }

    func close() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func makePanel() -> FloatingCardPanel {
        let p = FloatingCardPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 100),
                                  styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.delegate = self
        p.onCancel = { [weak self] in self?.close() }

        // The vibrancy material behind the SwiftUI content; a 1pt hairline
        // border keeps the card legible against a similarly-toned desktop.
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        p.contentView = effect
        return p
    }

    /// Closes on: clicking outside (global monitor for other apps, local
    /// monitor for this one), Esc (`FloatingCardPanel.cancelOperation`), the
    /// status item again (left to the button's own click action - the local
    /// monitor explicitly lets that click through untouched), or the app
    /// resigning active.
    private func installMonitors(button: NSStatusBarButton) {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.window === panel { return event }
            if event.window === button.window { return event }
            self.close()
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appResignedActive() { close() }

    func windowDidResignKey(_ notification: Notification) { close() }
}

/// A borderless, non-activating panel that still answers Esc: AppKit routes
/// an unclaimed Escape key press to `cancelOperation(_:)` up the responder
/// chain, which NSWindow does not implement by default, so this override is
/// what makes Esc close the panel with no default/cancel button in sight.
final class FloatingCardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
