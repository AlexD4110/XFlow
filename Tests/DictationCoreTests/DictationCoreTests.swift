import Testing
@testable import DictationCore

/// Proves the `swift test` harness discovers and runs a `DictationCore`
/// test target. Breaks if the core reports no version.
@Test func coreReportsAVersion() {
    #expect(!DictationCore.version.isEmpty)
}
