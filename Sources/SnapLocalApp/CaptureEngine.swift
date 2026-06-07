// CaptureEngine.swift
// SnapLocal - ScreenCaptureKit + Global Hotkey
//
// Copyright © 2024 SnapLocal. All rights reserved.

import Foundation
import ScreenCaptureKit
import Carbon
import CoreGraphics
import AppKit

// MARK: - CaptureEngine

final class CaptureEngine {
    typealias CaptureCompletion = (CGImage) -> Void

    private let hotkey: HotkeyConfig
    private let completion: CaptureCompletion
    private var hotkeyRef: EventHotKeyRef?
    private var stream: SCStream?

    init(hotkey: HotkeyConfig, completion: @escaping CaptureCompletion) {
        self.hotkey = hotkey
        self.completion = completion
    }

    deinit {
        unregisterHotkey()
    }

    // MARK: - Hotkey Registration

    func registerHotkey() {
        let eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let engine = Unmanaged<CaptureEngine>.fromOpaque(userData).takeUnretainedValue()
            engine.captureScreen()
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), &hotkeyRef)

        guard status == noErr, let hotkeyRef = hotkeyRef else {
            print("Failed to install hotkey handler")
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
            print("Failed to register hotkey: \(registerStatus)")
        }
    }

    func unregisterHotkey() {
        if let hotkeyRef = hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
    }

    // MARK: - Screen Capture

    func captureScreen() {
        Task { @MainActor in
            do {
                let image = try await captureWithScreenCaptureKit()
                completion(image)
            } catch {
                print("Capture failed: \(error)")
            }
        }
    }

    private func captureWithScreenCaptureKit() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        self.stream = stream

        let sampleBuffer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CMSampleBuffer, Error>) in
            let output = CaptureStreamOutput(continuation: continuation)
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                stream.startCapture()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        stream.stopCapture()
        stream.removeStreamOutput(output, type: .screen)

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw CaptureError.noImageBuffer
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(imageBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
              let cgImage = context.makeImage() else {
            throw CaptureError.contextCreationFailed
        }

        return cgImage
    }
}

// MARK: - Capture Stream Output

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    let continuation: CheckedContinuation<CMSampleBuffer, Error>

    init(continuation: CheckedContinuation<CMSampleBuffer, Error>) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            continuation.resume(returning: sampleBuffer)
        }
    }
}

// MARK: - Hotkey Config

struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayString: String

    static let `default` = HotkeyConfig(keyCode: 19, modifiers: cmdKey | shiftKey, displayString: "⌘⇧2") // Key code 19 = '2'

    // Alternative key codes
    static let alternatives: [HotkeyConfig] = [
        HotkeyConfig(keyCode: 19, modifiers: cmdKey | shiftKey, displayString: "⌘⇧2"),
        HotkeyConfig(keyCode: 28, modifiers: cmdKey | shiftKey, displayString: "⌘⇧6"), // Key code 28 = '6'
        HotkeyConfig(keyCode: 19, modifiers: cmdKey | controlKey, displayString: "⌘⌃2"),
        HotkeyConfig(keyCode: 19, modifiers: cmdKey | controlKey | shiftKey, displayString: "⌘⌃⇧2"),
    ]
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