// Settings.swift
// SnapLocal - UserDefaults + Hotkey Registration
//
// Copyright © 2024 SnapLocal. All rights reserved.

import Foundation
import Carbon
import SwiftUI
import ServiceManagement

// MARK: - Annotation Template

struct AnnotationTemplate: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var annotations: [AnyAnnotation]
}

// MARK: - Settings Keys

enum SettingsKey: String {
    case hotkeyKeyCode = "hotkey.keyCode"
    case hotkeyModifiers = "hotkey.modifiers"
    case hotkeyDisplayString = "hotkey.displayString"
    case saveDirectory = "save.directory"
    case notificationsEnabled = "notifications.enabled"
    case launchAtLogin = "launch.atLogin"
    case recentCustomColors = "color.recentCustomColors"
    case filenameTemplate = "filename.template"
    case captureWithCursor = "capture.withCursor"
    case autoCopyOnCapture = "capture.autoCopy"
    case openEditorOnCapture = "capture.openEditor"
    case annotationTemplates = "annotation.templates"
    case exportFormat = "export.format"        // "png" | "jpeg"
    case jpegQuality = "export.jpegQuality"    // 0.0-1.0
}

enum ExportFormat: String, CaseIterable {
    case png = "png"
    case jpeg = "jpeg"
    var displayName: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { rawValue }
}

// MARK: - Settings Manager

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults.standard
    
    private init() {
        registerDefaults()
    }
    
    private func registerDefaults() {
        let defaultHotkey = HotkeyConfig.default
        defaults.register(defaults: [
            SettingsKey.hotkeyKeyCode.rawValue: Int(defaultHotkey.keyCode),
            SettingsKey.hotkeyModifiers.rawValue: Int(defaultHotkey.modifiers),
            SettingsKey.hotkeyDisplayString.rawValue: defaultHotkey.displayString,
            SettingsKey.notificationsEnabled.rawValue: true,
            SettingsKey.launchAtLogin.rawValue: false,
            SettingsKey.autoCopyOnCapture.rawValue: true
        ])
    }
    
    // MARK: - Hotkey
    
    var hotkeyConfig: HotkeyConfig {
        get {
            let keyCode = UInt32(defaults.integer(forKey: SettingsKey.hotkeyKeyCode.rawValue))
            let modifiers = UInt32(defaults.integer(forKey: SettingsKey.hotkeyModifiers.rawValue))
            let displayString = defaults.string(forKey: SettingsKey.hotkeyDisplayString.rawValue) ?? HotkeyConfig.default.displayString
            return HotkeyConfig(keyCode: keyCode, modifiers: modifiers, displayString: displayString)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: SettingsKey.hotkeyKeyCode.rawValue)
            defaults.set(Int(newValue.modifiers), forKey: SettingsKey.hotkeyModifiers.rawValue)
            defaults.set(newValue.displayString, forKey: SettingsKey.hotkeyDisplayString.rawValue)
        }
    }
    
    var availableHotkeys: [HotkeyConfig] {
        HotkeyConfig.alternatives
    }
    
    // MARK: - Save Directory
    
    var saveDirectoryURL: URL {
        get {
            // 開発・スクリーンショット用オーバーライド(起動引数: -vault.directory.override <path>)。
            // UserDefaultsのargument domain経由なので通常起動には影響しない
            if let override = defaults.string(forKey: "vault.directory.override") {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            if let bookmarkData = defaults.data(forKey: SettingsKey.saveDirectory.rawValue) {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                    return url
                }
            }
            // Default to Pictures/SnapLocal
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            return pictures.appendingPathComponent("SnapLocal", isDirectory: true)
        }
        set {
            do {
                let bookmarkData = try newValue.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(bookmarkData, forKey: SettingsKey.saveDirectory.rawValue)
            } catch {
                print("Failed to save directory bookmark: \(error)")
            }
        }
    }
    
    // MARK: - Notifications
    
    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.notificationsEnabled.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.notificationsEnabled.rawValue) }
    }
    
    // MARK: - Launch at Login
    
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: SettingsKey.launchAtLogin.rawValue) }
        set {
            defaults.set(newValue, forKey: SettingsKey.launchAtLogin.rawValue)
            setLaunchAtLogin(newValue)
        }
    }

    // MARK: - Filename Template
    // Supported tokens: {date}, {time}, {width}, {height}, {title}

    var filenameTemplate: String {
        get { defaults.string(forKey: SettingsKey.filenameTemplate.rawValue) ?? "SnapLocal-{date}-{time}" }
        set { defaults.set(newValue, forKey: SettingsKey.filenameTemplate.rawValue) }
    }

    func filename(for date: Date, width: Int, height: Int, title: String?) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let tf = DateFormatter()
        tf.dateFormat = "HHmmss"
        var result = filenameTemplate
        result = result.replacingOccurrences(of: "{date}", with: df.string(from: date))
        result = result.replacingOccurrences(of: "{time}", with: tf.string(from: date))
        result = result.replacingOccurrences(of: "{width}", with: "\(width)")
        result = result.replacingOccurrences(of: "{height}", with: "\(height)")
        result = result.replacingOccurrences(of: "{title}", with: title?.replacingOccurrences(of: "/", with: "-") ?? "")
        // Sanitize: remove characters illegal in filenames
        let illegal = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        result = result.components(separatedBy: illegal).joined(separator: "-")
        return result.isEmpty ? "SnapLocal-\(df.string(from: date))-\(tf.string(from: date))" : result
    }

    // MARK: - Capture Cursor

    var captureWithCursor: Bool {
        get { defaults.bool(forKey: SettingsKey.captureWithCursor.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.captureWithCursor.rawValue) }
    }

    // MARK: - Auto-copy on capture

    var autoCopyOnCapture: Bool {
        get { defaults.bool(forKey: SettingsKey.autoCopyOnCapture.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.autoCopyOnCapture.rawValue) }
    }

    // MARK: - Open editor immediately after capture (skip HUD)

    var openEditorOnCapture: Bool {
        get { defaults.bool(forKey: SettingsKey.openEditorOnCapture.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.openEditorOnCapture.rawValue) }
    }

    // MARK: - Export Format

    var exportFormat: ExportFormat {
        get { ExportFormat(rawValue: defaults.string(forKey: SettingsKey.exportFormat.rawValue) ?? "png") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.exportFormat.rawValue) }
    }

    var jpegQuality: Double {
        get {
            let v = defaults.double(forKey: SettingsKey.jpegQuality.rawValue)
            return v == 0 ? 0.90 : v
        }
        set { defaults.set(newValue, forKey: SettingsKey.jpegQuality.rawValue) }
    }

    // MARK: - Recent Custom Colors (up to 5 hex strings "RRGGBBAA")

    var recentCustomColors: [String] {
        get { defaults.stringArray(forKey: SettingsKey.recentCustomColors.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: SettingsKey.recentCustomColors.rawValue) }
    }

    func addRecentCustomColor(_ hex: String) {
        var recent = recentCustomColors.filter { $0 != hex }
        recent.insert(hex, at: 0)
        if recent.count > 5 { recent = Array(recent.prefix(5)) }
        recentCustomColors = recent
        objectWillChange.send()
    }

    // MARK: - Annotation Templates

    var annotationTemplates: [AnnotationTemplate] {
        get {
            guard let data = defaults.data(forKey: SettingsKey.annotationTemplates.rawValue),
                  let templates = try? JSONDecoder().decode([AnnotationTemplate].self, from: data) else { return [] }
            return templates
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: SettingsKey.annotationTemplates.rawValue)
            }
            objectWillChange.send()
        }
    }

    func saveTemplate(name: String, annotations: [AnyAnnotation]) {
        let t = AnnotationTemplate(name: name, annotations: annotations)
        var templates = annotationTemplates
        templates.removeAll { $0.name == name }
        templates.insert(t, at: 0)
        annotationTemplates = templates
    }

    func deleteTemplate(id: UUID) {
        annotationTemplates.removeAll { $0.id == id }
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to set launch at login: \(error)")
        }
    }
}

// MARK: - Hotkey Config (shared with CaptureEngine)

struct HotkeyConfig: Codable, Equatable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayString: String
    
    // Carbon key codes
    private static let key2: UInt32 = 19
    private static let key6: UInt32 = 28
    
    // Carbon modifier masks as UInt32
    private static let cmdMask: UInt32 = UInt32(cmdKey)
    private static let shiftMask: UInt32 = UInt32(shiftKey)
    private static let controlMask: UInt32 = UInt32(controlKey)
    
    static let `default` = HotkeyConfig(keyCode: key2, modifiers: cmdMask | shiftMask, displayString: "⌘⇧2")
    
    static let alternatives: [HotkeyConfig] = [
        HotkeyConfig(keyCode: key2, modifiers: cmdMask | shiftMask, displayString: "⌘⇧2"),
        HotkeyConfig(keyCode: key6, modifiers: cmdMask | shiftMask, displayString: "⌘⇧6"),
        HotkeyConfig(keyCode: key2, modifiers: cmdMask | controlMask, displayString: "⌘⌃2"),
        HotkeyConfig(keyCode: key2, modifiers: cmdMask | controlMask | shiftMask, displayString: "⌘⌃⇧2"),
    ]
}