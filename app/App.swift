import AppKit
import SafariServices

// The app that carries the extension.  Opening it once is what makes Safari
// list the extension; after that its only job is to say whether the
// extension is on and to take the person to Safari's settings.
let extensionID = "hu.triglavmodular.webmidi.Extension"

enum Text {
    static let title = "Web MIDI"
    static let explain = "Turn on the Web MIDI extension in Safari\u{2019}s settings. Each site then asks before it can use your MIDI devices."
    static let on = "The extension is on."
    static let off = "The extension is off."
    static let unknown = "Safari has not listed the extension yet. Quit Safari and open it again."
    static let open = "Open Safari Settings\u{2026}"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = Text.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: Text.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let explain = NSTextField(wrappingLabelWithString: Text.explain)
        explain.preferredMaxLayoutWidth = 300
        status.textColor = .secondaryLabelColor
        let button = NSButton(title: Text.open, target: self, action: #selector(openSettings))
        button.keyEquivalent = "\r"
        button.controlSize = .large
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }

        let text = NSStackView(views: [title, explain, status, button])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10
        text.setCustomSpacing(16, after: status)
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 34, left: 26, bottom: 26, right: 26)
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        if #available(macOS 26.0, *) {
            // Liquid Glass: the whole window is one glass pane over the desktop.
            window.isOpaque = false
            window.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.cornerRadius = 26
            glass.contentView = row
            window.contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .windowBackground
            material.blendingMode = .behindWindow
            row.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                row.topAnchor.constraint(equalTo: material.topAnchor),
                row.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            window.contentView = material
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func applicationDidBecomeActive(_ note: Notification) { refresh() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func refresh() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionID) { state, error in
            DispatchQueue.main.async {
                if let state = state, error == nil {
                    self.status.stringValue = state.isEnabled ? Text.on : Text.off
                } else {
                    self.status.stringValue = Text.unknown
                }
            }
        }
    }

    @objc func openSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionID) { _ in }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = {
    let menu = NSMenu(), item = NSMenuItem()
    menu.addItem(item)
    let sub = NSMenu()
    sub.addItem(withTitle: "Quit \(Text.title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = sub
    return menu
}()
app.run()
