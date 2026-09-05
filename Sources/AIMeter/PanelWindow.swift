import AppKit
import SwiftUI

@MainActor
final class CardPanelController: NSObject, NSWindowDelegate {
    let state = PanelState()
    private var panel: FloatingCardPanel?
    private var hosting: NSHostingView<PanelView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var anchorFrame: NSRect?
    private weak var anchorButton: NSStatusBarButton?
    private var waitingForFirstHeight = false
    private var lastMeasuredStack: [SettingsPage]?
    var dismissalSuspended = false

    var isVisible: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        state.onContentHeight = { [weak self] height in
            self?.receivedContentHeight(height)
        }
        state.onDismissalSuspended = { [weak self] suspended in
            self?.dismissalSuspended = suspended
        }
    }

    func toggle(from button: NSStatusBarButton) {
        if isVisible { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        state.nav.reset()
        lastMeasuredStack = nil
        let width: CGFloat = 372
        let hosting = NSHostingView(rootView: PanelView(state: state, requestClose: { [weak self] in
            self?.close()
        }))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting

        let p = panel ?? makePanel()
        p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        p.contentView?.addSubview(hosting)
        if let content = p.contentView {
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: content.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        panel = p
        anchorButton = button
        anchorFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? NSRect(x: 0, y: NSScreen.main?.frame.maxY ?? 800, width: 0, height: 0)
        state.screenLimit = maxHeight(for: p)
        waitingForFirstHeight = true
        position(width: width, height: 120, display: false, animated: false)
        hosting.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, self.waitingForFirstHeight, let button else { return }
            self.reveal(button: button)
        }
    }

    func setContentHeight(_ height: CGFloat, animated: Bool) {
        guard let p = panel, p.isVisible || waitingForFirstHeight else { return }
        let target = max(120, min(height, maxHeight(for: p)))
        guard abs(p.frame.height - target) > 0.5 else { return }
        position(width: p.frame.width, height: target, display: true, animated: animated)
    }

    private func receivedContentHeight(_ height: CGFloat) {
        guard let p = panel else { return }
        let stack = state.nav.stack
        let samePage = lastMeasuredStack == stack
        lastMeasuredStack = stack
        let shouldAnimate = p.isVisible && samePage && state.animate
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setContentHeight(height, animated: shouldAnimate)
        if waitingForFirstHeight, let button = anchorButton {
            reveal(button: button)
        }
    }

    private func reveal(button: NSStatusBarButton) {
        guard waitingForFirstHeight, let p = panel else { return }
        waitingForFirstHeight = false
        p.makeKeyAndOrderFront(nil)
        installMonitors(button: button)
    }

    func close() {
        panel?.orderOut(nil)
        waitingForFirstHeight = false
        dismissalSuspended = false
        removeMonitors()
    }

    private func maxHeight(for panel: NSPanel) -> CGFloat {
        let screen = panel.screen ?? NSScreen.main
        return (screen?.visibleFrame.height ?? 736) - 16
    }

    private func position(width: CGFloat, height: CGFloat, display: Bool, animated: Bool) {
        guard let p = panel, let anchor = anchorFrame else { return }
        let frame = NSRect(x: anchor.maxX - width, y: anchor.minY - 8 - height,
                           width: width, height: height)
        hosting?.layoutSubtreeIfNeeded()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                p.animator().setFrame(frame, display: display)
            }
        } else {
            p.setFrame(frame, display: display)
        }
    }

    private func makePanel() -> FloatingCardPanel {
        let p = FloatingCardPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 100),
                                  styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.delegate = self
        p.onEscape = { [weak self] in self?.handleEscape() }

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

    private func handleEscape() {
        switch escapeAction(stackDepth: state.nav.stack.count) {
        case .pop: state.nav.pop()
        case .close: close()
        }
    }

    private func installMonitors(button: NSStatusBarButton) {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, !self.dismissalSuspended else { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, !self.dismissalSuspended,
                  let panel = self.panel, panel.isVisible else { return event }
            if event.window === panel || event.window === button.window { return event }
            self.close()
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    private func removeMonitors() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification,
                                                  object: nil)
    }

    @objc private func appResignedActive() {
        guard !dismissalSuspended else { return }
        close()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !dismissalSuspended else { return }
        close()
    }
}

final class FloatingCardPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
