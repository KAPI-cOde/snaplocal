// App.swift
// SnapLocal - Menu Bar App + AppDelegate
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import AppKit
import Carbon
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var captureEngine: CaptureEngine?
    private var settingsWindow: NSWindow?
    private let tempVault = TempVault.shared
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verify security on launch
        Security.verifySignature()

        // Setup menu bar
        setupMenuBar()

        // Initialize capture engine with default hotkey
        captureEngine = CaptureEngine(hotkey: settings.hotkey) { [weak self] image in
            self?.showAnnotationWindow(with: image)
        }
        captureEngine?.registerHotkey()

        // Register for settings changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyChanged),
            name: Settings.hotkeyChangedNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureEngine?.unregisterHotkey()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapLocal")
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            captureEngine?.captureScreen()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // Recent captures
        let historyMenu = NSMenu(title: "履歴")
        let items = tempVault.getRecentItems(limit: 10)
        if items.isEmpty {
            let item = NSMenuItem(title: "履歴がありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            historyMenu.addItem(item)
        } else {
            for item in items {
                let menuItem = NSMenuItem(title: item.displayName, action: #selector(historyItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item
                menuItem.image = item.thumbnail
                historyMenu.addItem(menuItem)
            }
        }
        menu.addItem(NSMenuItem(title: "履歴", action: nil, keyEquivalent: "").withSubmenu(historyMenu))

        menu.addItem(NSMenuItem.separator())

        // Actions
        menu.addItem(NSMenuItem(title: "範囲選択スクショ (⌘⇧2)", action: #selector(captureScreen), keyEquivalent: "2").withKeyEquivalentModifierMask([.command, .shift]))
        menu.addItem(NSMenuItem(title: "設定...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func captureScreen() {
        captureEngine?.captureScreen()
    }

    @objc private func historyItemClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? VaultItem else { return }
        tempVault.promoteToL3(item.id) { result in
            switch result {
            case .success(let url):
                NSWorkspace.shared.open(url)
            case .failure(let error):
                self.showError(error)
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environmentObject(settings)
                .environmentObject(tempVault)
            let hostingController = NSHostingController(rootView: settingsView)
            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = "SnapLocal 設定"
            settingsWindow?.setContentSize(NSSize(width: 480, height: 400))
            settingsWindow?.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func hotkeyChanged() {
        captureEngine?.unregisterHotkey()
        captureEngine = CaptureEngine(hotkey: settings.hotkey) { [weak self] image in
            self?.showAnnotationWindow(with: image)
        }
        captureEngine?.registerHotkey()
    }

    // MARK: - Annotation Window

    private func showAnnotationWindow(with image: CGImage) {
        let annotationWindow = AnnotationWindow(image: image) { [weak self] annotatedImage in
            self?.tempVault.save(annotatedImage)
        }
        annotationWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

// MARK: - NSMenuItem Extensions

extension NSMenuItem {
    func withSubmenu(_ submenu: NSMenu) -> NSMenuItem {
        self.submenu = submenu
        return self
    }

    func withKeyEquivalentModifierMask(_ mask: NSEvent.ModifierFlags) -> NSMenuItem {
        self.keyEquivalentModifierMask = mask
        return self
    }
}