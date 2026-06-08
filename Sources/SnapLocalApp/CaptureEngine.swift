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
    private var eventHandler: EventHandlerRef?

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
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let engine = Unmanaged<CaptureEngine>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                engine.captureScreen()
            }
            return noErr
        }, 1, &eventSpec, selfRef, &eventHandler)

        guard status == noErr else {
            logger.error("Failed to install hotkey handler: \\(status)")
            return
        }

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
    }

    nonisolated func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Screen Capture

    nonisolated func captureScreen() {
        logger.debug("captureScreen() called")
        Task {
            do {
                logger.debug("Checking screen capture access...")
                guard CGPreflightScreenCaptureAccess() else {
                    logger.debug("No screen capture access, requesting...")
                    _ = CGRequestScreenCaptureAccess()
                    throw CaptureError.permissionDenied
                }
                logger.debug("Screen capture access granted, capturing...")
                let image = try await captureWithScreenCaptureKit()
                logger.debug("Capture succeeded, calling completion")
                await MainActor.run { self.completion(.success(image)) }
            } catch {
                let errorDesc = String(describing: error)
                logger.error("Capture failed: \(errorDesc, privacy: .public)")
                await MainActor.run { self.completion(.failure(error)) }
            }
        }
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

        // Prefer main display
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
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
        configuration.showsCursor = false
        configuration.capturesAudio = false
        // Don't use scalesToFit - we set exact pixel dimensions
        configuration.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = CaptureStreamOutput()

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CMSampleBuffer, Error>) in
                output.continuation = continuation
                do {
                    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                    logger.debug("Starting screen capture stream...")
                    stream.startCapture()
                    // FIX: Add small delay to ensure stream is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        logger.debug("Stream started, waiting for first frame...")
                    }
                } catch {
                    logger.error("stream.addStreamOutput/startCapture failed: \(String(describing: error))")
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            logger.error("Failed to get sampleBuffer: \(String(describing: error))")
            throw error
        }

        logger.debug("Got sample buffer, stopping stream...")
        do {
            try await stream.stopCapture()
            try stream.removeStreamOutput(output, type: .screen)
        } catch {
            logger.error("stream.stopCapture/removeStreamOutput failed: \(String(describing: error))")
            throw error
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("CMSampleBufferGetImageBuffer returned nil")
            throw CaptureError.noImageBuffer
        }

        logger.debug("Got imageBuffer, converting with Core Image...")
        // Use Core Image for robust pixel format handling
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            logger.error("ERROR: Core Image conversion failed")
            throw CaptureError.contextCreationFailed
        }

        logger.info("Screenshot captured successfully via Core Image: \(cgImage.width)x\(cgImage.height)")
        return cgImage
    }
}

// MARK: - Capture Stream Output

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    var continuation: CheckedContinuation<CMSampleBuffer, Error>?
    private var hasReceived = false

    override init() {}

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let continuation, !hasReceived else { return }
        hasReceived = true
        self.continuation = nil
        
        // FIX: Capture sampleBuffer in a local var to satisfy sendable checking
        let buffer = sampleBuffer
        continuation.resume(returning: buffer)
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