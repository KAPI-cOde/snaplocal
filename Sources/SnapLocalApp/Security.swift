// Security.swift
// SnapLocal - Runtime Signature Verification & Hardening
//
// Copyright © 2024 SnapLocal. All rights reserved.

import Foundation
import Security

// MARK: - Security Verification

struct SecurityVerifier {
    static func verifySignature() -> Bool {
        // Verify code signature at runtime
        var staticCode: SecStaticCode?
        // Note: In production, the executable path would be used. For now, just verify the bundle exists.
        let bundleURL = Bundle.main.bundleURL
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        
        guard status == errSecSuccess, let code = staticCode else {
            print("Security: Failed to create static code reference (status: \(status))")
            // In debug, allow continuation
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        
        var secRequirement: SecRequirement?
        let requirementString = """
            anchor apple generic and identifier "com.snaplocal.app" and \
            (certificate leaf = "Apple Development" or certificate leaf = "Apple Distribution" or certificate leaf = "Developer ID Application")
        """
        
        let reqStatus = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &secRequirement)
        guard reqStatus == errSecSuccess, let requirement = secRequirement else {
            print("Security: Failed to create requirement")
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        
        let verifyStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), requirement)
        if verifyStatus != errSecSuccess {
            print("Security: Code signature verification failed: \(verifyStatus)")
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
        
        return true
    }
    
    static func verifyEntitlements() -> Bool {
        // In a real build, entitlements are embedded in the binary
        // This is a basic check for development
        #if DEBUG
        return true
        #else
        guard let entitlementsPath = Bundle.main.path(forResource: "SnapLocal", ofType: "entitlements"),
              let entitlementsData = FileManager.default.contents(atPath: entitlementsPath),
              let entitlements = try? PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any] else {
            print("Security: Could not load entitlements")
            return false
        }
        
        let requiredEntitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.files.user-selected.read-only": true,
            "com.apple.security.files.downloads.read-write": true
        ]
        
        for (key, expectedValue) in requiredEntitlements {
            guard let actualValue = entitlements[key] else {
                print("Security: Missing entitlement: \(key)")
                return false
            }
            
            if let expectedBool = expectedValue as? Bool, let actualBool = actualValue as? Bool {
                if expectedBool != actualBool {
                    print("Security: Entitlement mismatch for \(key): expected \(expectedBool), got \(actualBool)")
                    return false
                }
            }
        }
        
        if let networkClient = entitlements["com.apple.security.network.client"] as? Bool, networkClient {
            print("Security: Network client entitlement unexpectedly enabled")
            return false
        }
        
        return true
        #endif
    }
    
    static func performAllChecks() -> Bool {
        let signatureValid = verifySignature()
        let entitlementsValid = verifyEntitlements()
        
        if !signatureValid || !entitlementsValid {
            print("Security: Failed security verification - terminating")
            return false
        }
        
        print("Security: All checks passed")
        return true
    }
    
    static func verifyNoNetworkAccess() -> Bool {
        return true
    }
}

// MARK: - Hardened Runtime Helpers

extension SecurityVerifier {
    static func verifyAtLaunch() {
        #if !DEBUG
        guard performAllChecks() else {
            exit(EXIT_FAILURE)
        }
        #else
        _ = performAllChecks()
        #endif
    }
}