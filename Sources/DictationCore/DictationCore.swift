/// The core of the local dictation app: all logic lives here so it can be
/// exercised by `swift test` without a microphone, a permission grant, or a
/// model file. The menu-bar app target is a thin shell over this library.
public enum DictationCore {
    /// Version of the core library.
    public static let version = "0.0.1"
}
