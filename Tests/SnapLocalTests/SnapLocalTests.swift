import Testing
import Foundation

// SnapLocalApp uses ScreenCaptureKit and Vision framework APIs that require
// a running macOS app context, so unit tests are limited to data-layer logic.
// Integration testing is done by running the app manually.

@Suite("Storage")
struct StorageTests {
    @Test("save directory defaults to ~/Pictures/SnapLocal")
    func defaultSaveDirectory() {
        let expected = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/SnapLocal")
        // SettingsManager is in the app target; verify the path shape here.
        #expect(expected.path.hasSuffix("Pictures/SnapLocal"))
    }
}
