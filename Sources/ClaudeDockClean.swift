import AppKit
import ApplicationServices
import ServiceManagement

/// Claude icons beyond the one pinned tile.
func extraClaudeCount(_ total: Int) -> Int {
    max(0, total - 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let countItem = NSMenuItem()
    private let cleanItem = NSMenuItem(title: "Clean up", action: #selector(cleanUp), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Allow Dock counting…", action: #selector(requestAccess), keyEquivalent: "")
    private let relaunchItem = NSMenuItem(title: "Relaunch to apply access", action: #selector(relaunch), keyEquivalent: "")
    private var timer: Timer?
    private var isCleaning = false
    private var lastCount: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self

        countItem.isEnabled = false
        menu.addItem(countItem)
        cleanItem.target = self
        menu.addItem(cleanItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        accessItem.target = self
        menu.addItem(accessItem)
        relaunchItem.target = self
        menu.addItem(relaunchItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        if let image = NSImage(systemSymbolName: "c.square", accessibilityDescription: "Claude Dock Clean") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeading
        } else {
            statusItem.button?.title = "C"
        }

        applyCount(nil)
        refreshCount()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            self?.refreshCount()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshCount()
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        if status == .requiresApproval {
            loginItem.title = "Open at Login (approval needed)"
        } else {
            loginItem.title = "Open at Login"
        }
        let trusted = AXIsProcessTrusted()
        accessItem.isHidden = trusted
        relaunchItem.isHidden = trusted
    }

    private func refreshCount() {
        guard !isCleaning else { return }
        guard AXIsProcessTrusted() else {
            lastCount = nil
            applyCount(nil)
            return
        }
        let total = claudeDockItemCount()
        lastCount = total
        applyCount(total)
    }

    private func applyCount(_ total: Int?) {
        let extras = total.map(extraClaudeCount)
        if let extras, extras > 0 {
            statusItem.button?.title = " \(extras)"
            countItem.title = extras == 1
                ? "1 extra Claude icon"
                : "\(extras) extra Claude icons"
            cleanItem.title = "Clean up"
        } else if total != nil {
            statusItem.button?.title = ""
            countItem.title = "Dock looks fine"
            cleanItem.title = "Clean up anyway"
        } else {
            statusItem.button?.title = ""
            countItem.title = "Dock access is still off for this launch"
            cleanItem.title = "Clean up"
        }
        statusItem.button?.toolTip = countItem.title
    }

    @objc private func cleanUp() {
        guard !isCleaning else { return }
        isCleaning = true
        countItem.title = "Restarting the Dock…"
        cleanItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            _ = runTool("/usr/bin/defaults", ["delete", "com.apple.dock", "recent-apps"])
            _ = runTool("/usr/bin/killall", ["-9", "Dock"])
            DispatchQueue.main.async {
                self.cleanItem.isEnabled = true
                self.isCleaning = false
                self.refreshCount()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.refreshCount()
                }
            }
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            countItem.title = "Login item failed: \(error.localizedDescription)"
        }
        loginItem.state = service.status == .enabled ? .on : .off
    }

    @objc private func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func claudeDockItemCount() -> Int {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        return 0
    }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    return countClaudeItems(in: app, depth: 0)
}

private func countClaudeItems(in element: AXUIElement, depth: Int) -> Int {
    if depth > 6 { return 0 }
    var found = 0
    if axString(element, kAXRoleAttribute) == "AXDockItem",
       axString(element, kAXTitleAttribute) == "Claude" {
        found = 1
    }
    for child in axChildren(element) {
        found += countClaudeItems(in: child, depth: depth + 1)
    }
    return found
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value as? String
}

private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let value else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return -1
    }
}

if CommandLine.arguments.contains("--count") {
    if !AXIsProcessTrusted() {
        fputs("untrusted\n", stderr)
        exit(2)
    }
    let total = claudeDockItemCount()
    print("\(total) \(extraClaudeCount(total))")
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
