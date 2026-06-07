// main.swift
// CLI entry point for SnapLocal

import SnapLocalCore
import Foundation

print("SnapLocal CLI")
print("Available storage tiers:")
for tier in StorageTier.allCases {
    print("  - \(tier.rawValue)")
}

let metadata = ItemMetadata(title: "Test Item", tags: ["demo", "cli"])
let item = TempVaultItem(tier: .clean, originalData: Data("Hello, SnapLocal!".utf8), metadata: metadata)
print("\nCreated item: \(item.id)")
print("Tier: \(item.tier.rawValue)")
print("Title: \(item.metadata.title)")
print("Tags: \(item.metadata.tags)")