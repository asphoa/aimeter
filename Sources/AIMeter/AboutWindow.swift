import AppKit
import SwiftUI

/// The version string embedded by build.sh (CFBundleShortVersionString, taken
/// from the repo-root VERSION file) - falls back to "dev" for a binary run
/// straight out of `swiftc` without going through the packaging step.
private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            Text("AIMeter").font(.title2).bold()
            Text(L.t("a.version", appVersion))
                .font(.callout)
                .foregroundColor(.secondary)
            Text(L.t("a.tagline"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Text(L.t("a.noassets"))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Link(L.t("a.source"), destination: URL(string: "https://github.com/asphoa/aimeter")!)
                .font(.callout)
            Text(L.t("a.license"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 320)
    }
}

/// Lets main.swift's `--about` offscreen renderer reach the view without
/// making it public API.
@MainActor
func aboutViewForRendering() -> some View { AboutView() }

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: AboutView())
        let w = NSWindow(contentViewController: host)
        w.title = L.t("m.about")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
