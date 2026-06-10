// Utilities.swift
// SnapLocal — 共通ユーティリティ(R2.2 重複排除)
//
// Copyright © 2024 SnapLocal. All rights reserved.

import AppKit
import CoreGraphics

// MARK: - CGImage helpers

extension CGImage {
    /// PNG データに変換する。PersistentVault / StateExport 両者の private pngData(from:) を統合。
    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }

    /// ピクセルサイズと同じ論理サイズの NSImage を返す。
    /// size がピクセルサイズそのままのパターンのみ対象。違うサイズを渡している箇所は触らない。
    var nsImage: NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

// MARK: - NSApplication helpers

extension NSApplication {
    /// アプリを最前面に持ってくる2行セット。
    /// 2行が完全一致するペア5箇所を統合(片方のみ・間に別コードが挟まる箇所は除外)。
    @MainActor
    func bringToFront() {
        activate(ignoringOtherApps: true)
        windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - DateFormatter helpers

extension DateFormatter {
    /// ファイル名用タイムスタンプ "yyyyMMdd-HHmmss"。StateExport 3箇所の重複を統合。
    static let fileTimestamp: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()
}
