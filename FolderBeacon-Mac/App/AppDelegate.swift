import AppKit
import Sparkle
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem!
    private var appWindowController: NSWindowController?
    private var languageObserver: NSObjectProtocol?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var hasUpdateFeed: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return false }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if hasUpdateFeed {
            updaterController.startUpdater()
        }
        configureMenuBar()
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.configureMenuBar()
        }
        state.start()
        let onboardingKey = "FolderBeacon.didShowGettingStarted.v1"
        if !UserDefaults.standard.bool(forKey: onboardingKey) || !AccessibilityPermissionManager.isTrusted {
            UserDefaults.standard.set(true, forKey: onboardingKey)
            showAppWindow(page: .gettingStarted)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // System Settings changes Accessibility permission while the app is inactive.
        // Defer the published update until AppKit completes its activation layout pass.
        DispatchQueue.main.async { [weak self] in
            self?.state.refreshAccessibilityState()
            self?.state.refreshFinderPermission()
            self?.state.folderIndex.refreshProtectedFolderAccess()
        }
    }

    private func configureMenuBar() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = BrandIcon.menuBarImage()
        }
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        let panelItem = statusItem.menu?.addItem(withTitle: L10n.string("Start Search"), action: #selector(showFolderPanel), keyEquivalent: "")
        panelItem?.keyEquivalentModifierMask = [.option]
        panelItem?.keyEquivalent = " "
        statusItem.menu?.addItem(NSMenuItem.separator())
        statusItem.menu?.addItem(withTitle: L10n.string("Getting Started…"), action: #selector(openGettingStarted), keyEquivalent: "")
        statusItem.menu?.addItem(withTitle: L10n.string("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        let permissionItem = statusItem.menu?.addItem(withTitle: L10n.string("Enable Automatic Popup…"), action: #selector(enableAutomaticPopup), keyEquivalent: "")
        permissionItem?.tag = 42
        permissionItem?.isHidden = AccessibilityPermissionManager.isTrusted
        let updateItem = statusItem.menu?.addItem(
            withTitle: L10n.string("Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem?.target = self
        updateItem?.isEnabled = hasUpdateFeed
        statusItem.menu?.addItem(NSMenuItem.separator())
        statusItem.menu?.addItem(withTitle: L10n.string("Quit FolderBeacon"), action: #selector(quit), keyEquivalent: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        UsageAnalytics.capture(.menuOpened)
        menu.item(withTag: 42)?.isHidden = AccessibilityPermissionManager.isTrusted
        DispatchQueue.main.async { [weak self] in self?.state.refreshAccessibilityState() }
    }

    @objc private func enableAutomaticPopup() {
        showAppWindow(page: .permissions)
        state.requestAccessibilityPermission()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UsageAnalytics.capture(.menuUpdates)
        updaterController.checkForUpdates(sender)
    }

    @objc private func openSettings() {
        UsageAnalytics.capture(.menuSettings)
        showAppWindow(page: .general)
    }

    @objc private func openGettingStarted() {
        UsageAnalytics.capture(.menuGettingStarted)
        showAppWindow(page: .gettingStarted)
    }

    private func showAppWindow(page: SettingsPage) {
        // FolderBeacon is normally an accessory menu-bar utility. Make the
        // settings window a regular app window so users can recover it from
        // Dock and Command-Tab if another app covers it.
        NSApp.setActivationPolicy(.regular)
        state.openSettings(page)
        if appWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "FolderBeacon"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(state: state, initialPage: page))
            appWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        appWindowController?.showWindow(nil)
        appWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === appWindowController?.window else { return }
        // The quick panel remains a lightweight accessory utility when no
        // settings window is visible.
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func showFolderPanel() {
        UsageAnalytics.capture(.menuSearch)
        state.showQuickPanel()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
