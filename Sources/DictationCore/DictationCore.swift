/// The core of the local dictation app: all logic lives here so it can be
/// exercised by `swift test` without a microphone, a permission grant, or a
/// model file. The menu-bar app target is a thin shell over this library.
public enum DictationCore {
    /// Version of the core library.
    public static let version = "0.0.1"

    /// Entry point the menu-bar app shell hands control to. Later phases grow
    /// this into the real menu-bar lifecycle (event tap, audio, insertion);
    /// at scaffold stage it just announces startup so the executable is
    /// runnable without any OS permission grant.
    public static func launch() {
        print("DictationApp \(version) — scaffold")
    }
}
