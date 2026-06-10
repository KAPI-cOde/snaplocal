// CaptureEngine.swift
// SnapLocal - ScreenCaptureKit + Global Hotkey
//
// Copyright © 2024 SnapLocal. All rights reserved.

// Disable strict concurrency checking for this file
#if swift(>=6.0)
@preconcurrency import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import Carbon
@preconcurrency import CoreGraphics
@preconcurrency import AppKit
@preconcurrency import OSLog
@preconcurrency import CoreImage
#else
import Foundation
import ScreenCaptureKit
import Carbon
import CoreGraphics
import AppKit
import OSLog
import CoreImage
#endif

private let logger = Logger(subsystem: "com.snaplocal.app", category: "CaptureEngine")

// MARK: - CaptureEngine

final class CaptureEngine: @unchecked Sendable {
    typealias CaptureCompletion = @Sendable (Result<CGImage, Error>) -> Void

    private let hotkey: HotkeyConfig
    private let completion: CaptureCompletion
    private var hotkeyRef: EventHotKeyRef?
    private var regionHotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var regionCaptureAction: (@Sendable () -> Void)?

    init(hotkey: HotkeyConfig, completion: @escaping CaptureCompletion) {
        self.hotkey = hotkey
        self.completion = completion
    }

    deinit {
        unregisterHotkey()
    }

    // MARK: - Hotkey Registration

    nonisolated func registerHotkey() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let selfRef = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
            let engine = Unmanaged<CaptureEngine>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                if hkID.id == 2 {
                    engine.regionCaptureAction?()
                } else {
                    engine.captureScreen()
                }
            }
            return noErr
        }, 1, &eventSpec, selfRef, &eventHandler)

        guard status == noErr else {
            logger.error("Failed to install hotkey handler: \\(status)")
            return
        }

        // Full-screen hotkey (user-configurable)
        let hotkeyID = EventHotKeyID(signature: OSType(0x534E4C43), id: 1) // 'SNLC'
        let registerStatus = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if registerStatus != noErr {
            logger.error("Failed to register hotkey: \\(registerStatus)")
        }

        // Region capture hotkey: ⌘⇧4 (hardcoded; key 21 = 4)
        let cmdShift = UInt32(cmdKey | shiftKey)
        let regionID = EventHotKeyID(signature: OSType(0x534E4C43), id: 2)
        RegisterEventHotKey(21, cmdShift, regionID, GetApplicationEventTarget(), 0, &regionHotkeyRef)
    }

    nonisolated func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        if let regionHotkeyRef = regionHotkeyRef { UnregisterEventHotKey(regionHotkeyRef) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Screen Capture

    nonisolated func captureScreen() {
        logger.debug("captureScreen() called")
        Task {
            do {
                guard CGPreflightScreenCaptureAccess() else {
                    _ = CGRequestScreenCaptureAccess()
                    throw CaptureError.permissionDenied
                }
                let image = try await captureWithScreenCaptureKit()
                await MainActor.run { self.completion(.success(image)) }
            } catch {
                let errorDesc = String(describing: error)
                logger.error("Capture failed: \(errorDesc, privacy: .public)")
                await MainActor.run { self.completion(.failure(error)) }
            }
        }
    }

    /// Capture a specific region (in global CG coordinates: top-left origin, primary display at origin).
    /// Supports multi-display: finds the display containing the region and captures from it.
    nonisolated func captureRegion(_ regionInPoints: CGRect) {
        Task {
            do {
                guard CGPreflightScreenCaptureAccess() else {
                    _ = CGRequestScreenCaptureAccess()
                    throw CaptureError.permissionDenied
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

                // Find the display that contains the center of the selected region
                let center = CGPoint(x: regionInPoints.midX, y: regionInPoints.midY)
                let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) })
                    ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first
                guard let display else { throw CaptureError.noDisplay }

                let fullImage = try await captureDisplayImage(display: display, content: content)

                // Compute region relative to this display's origin (in logical points)
                let displayBounds = CGDisplayBounds(display.displayID)
                let relativeRect = CGRect(
                    x: regionInPoints.minX - displayBounds.minX,
                    y: regionInPoints.minY - displayBounds.minY,
                    width: regionInPoints.width,
                    height: regionInPoints.height
                )

                // Scale to physical pixels
                let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                })
                let scale = screen?.backingScaleFactor ?? 2.0
                let pixelRect = CGRect(
                    x: relativeRect.minX * scale,
                    y: relativeRect.minY * scale,
                    width: relativeRect.width * scale,
                    height: relativeRect.height * scale
                )

                guard let cropped = fullImage.cropping(to: pixelRect) else {
                    throw CaptureError.noImageBuffer
                }
                await MainActor.run { self.completion(.success(cropped)) }
            } catch {
                await MainActor.run { self.completion(.failure(error)) }
            }
        }
    }

    /// Capture a single display, excluding our own app windows.
    private func captureDisplayImage(display: SCDisplay, content: SCShareableContent) async throws -> CGImage {
        let ourBundleID = Bundle.main.bundleIdentifier ?? "com.snaplocal.app"
        let ourApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])

        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        })
        let displayScale = screen?.backingScaleFactor ?? 1.0

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * displayScale)
        config.height = Int(CGFloat(display.height) * displayScale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = await MainActor.run { SettingsManager.shared.captureWithCursor }
        config.capturesAudio = false
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = CaptureStreamOutput()
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            output.continuation = continuation
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                stream.startCapture()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .screen)
        return cgImage
    }

    /// Fetch list of capturable windows (excludes our own app and wallpaper).
    /// SCWindowは非SendableなのでMainActorに固定して境界越えを防ぐ。
    @MainActor
    static func availableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ourBundleID = Bundle.main.bundleIdentifier ?? "com.snaplocal.app"
        return content.windows.filter { w in
            w.owningApplication?.bundleIdentifier != ourBundleID &&
            w.frame.width > 50 && w.frame.height > 50 &&
            w.isOnScreen
        }
    }

    /// Capture a specific SCWindow.
    nonisolated func captureWindow(_ window: SCWindow) {
        Task {
            do {
                guard CGPreflightScreenCaptureAccess() else {
                    _ = CGRequestScreenCaptureAccess()
                    throw CaptureError.permissionDenied
                }
                let image = try await captureWindowImage(window)
                await MainActor.run { self.completion(.success(image)) }
            } catch {
                await MainActor.run { self.completion(.failure(error)) }
            }
        }
    }

    private func captureWindowImage(_ window: SCWindow) async throws -> CGImage {
        // Try CGWindowListCreateImage first for shadow-inclusive capture
        if let cgResult = captureWindowWithShadow(window) { return cgResult }

        // Fallback: ScreenCaptureKit (no shadow)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = await MainActor.run { SettingsManager.shared.captureWithCursor }
        config.capturesAudio = false
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = CaptureStreamOutput()
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            output.continuation = continuation
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                stream.startCapture()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .screen)
        return cgImage
    }

    private func captureWindowWithShadow(_ window: SCWindow) -> CGImage? {
        let windowID = CGWindowID(window.windowID)
        // .null rect + no .boundsIgnoreFraming → bounds includes the window shadow
        let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            .bestResolution
        )
        return image
    }

    private func captureWithScreenCaptureKit() async throws -> CGImage {
        logger.debug("Getting shareable content...")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            logger.error("SCShareableContent failed: \(String(describing: error))")
            throw error
        }
        logger.debug("Shareable content: \(content.displays.count) displays, \(content.windows.count) windows")

        // Prefer display where mouse cursor is; fall back to main display
        let mouseLocation = NSEvent.mouseLocation
        let cursorDisplayID = NSScreen.screens.first(where: { NSPointInRect(mouseLocation, $0.frame) })
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        guard let display = content.displays.first(where: { $0.displayID == cursorDisplayID })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            logger.error("No display found")
            throw CaptureError.noDisplay
        }
        logger.debug("Using display: \(display.width)x\(display.height), ID: \(display.displayID)")

        // Get display scale factor for Retina
        let displayScale = NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == display.displayID })?.backingScaleFactor ?? 1.0
        logger.debug("Display scale factor: \(displayScale)")

        // Exclude our own app windows
        let ourBundleID = Bundle.main.bundleIdentifier ?? "com.snaplocal.app"
        logger.debug("Our bundle ID: \(ourBundleID)")
        let ourApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
        logger.debug("Excluding \(ourApps.count) own app(s)")

        let configuration = SCStreamConfiguration()
        // Set width/height in PHYSICAL PIXELS (not points) for Retina
        configuration.width = Int(CGFloat(display.width) * displayScale)
        configuration.height = Int(CGFloat(display.height) * displayScale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = await MainActor.run { SettingsManager.shared.captureWithCursor }
        configuration.capturesAudio = false
        // Don't use scalesToFit - we set exact pixel dimensions
        configuration.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = CaptureStreamOutput()

        let cgImage: CGImage
        do {
            cgImage = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                output.continuation = continuation
                do {
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                    logger.debug("Starting screen capture stream...")
                    stream.startCapture()
                } catch {
                    logger.error("stream.addStreamOutput/startCapture failed: \(String(describing: error))")
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            logger.error("Failed to get CGImage from stream: \(String(describing: error))")
            throw error
        }

        logger.debug("Got CGImage, stopping stream...")
        do {
            try await stream.stopCapture()
            try stream.removeStreamOutput(output, type: .screen)
        } catch {
            logger.error("stream.stopCapture/removeStreamOutput failed: \(String(describing: error))")
            throw error
        }

        logger.info("Screenshot captured successfully: \(cgImage.width)x\(cgImage.height)")
        return cgImage
    }
}

// MARK: - Capture Stream Output

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    var continuation: CheckedContinuation<CGImage, Error>?
    private var hasReceived = false

    override init() {}

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let continuation, !hasReceived else { return }
        hasReceived = true
        self.continuation = nil

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            continuation.resume(throwing: CaptureError.noImageBuffer)
            return
        }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            continuation.resume(throwing: CaptureError.contextCreationFailed)
            return
        }
        continuation.resume(returning: cgImage)
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noDisplay
    case noImageBuffer
    case contextCreationFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "ディスプレイが見つかりません"
        case .noImageBuffer: return "画像バッファの取得に失敗しました"
        case .contextCreationFailed: return "画像コンテキストの作成に失敗しました"
        case .permissionDenied: return "画面録画の権限がありません。システム設定 > プライバシーとセキュリティ > 画面録画で許可してください。"
        }
    }
}