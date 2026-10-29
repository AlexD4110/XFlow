 Local Dictation App — Build Spec

Oct 28, 2026 · @Alex

A free, unlimited, fully-local macOS voice-dictation app, modeled on a reference dictation app's behavior but with on-device transcription and no cloud or account dependency.

---

## 1. Purpose & Scope

Build a macOS dictation app that turns held-key speech into text pasted at the cursor, running entirely on-device so it is free and has no usage limit.

**In scope**
- Global push-to-talk hotkey (fn), captured system-wide.
- On-device speech-to-text with whisper.cpp.
- On-device text cleanup with a small local LLM (fillers, punctuation, light formatting).
- Insert the result into whatever app has focus, via the clipboard.
- Minimal UI: a status/recording indicator and the macOS permission prompts.

**Non-goals**
- No cloud transcription, account, or network dependency. The pipeline is local by design.
- No reuse of the reference app's servers, endpoints, auth tokens, or licensed assets. The reference app is studied only as a behavioral reference for an app the builder owns a copy of.
- Not a line-for-line clone of the reference app's code or UI; we mirror mechanisms, not source.

**Target platform:** macOS on Apple Silicon (primary). A native helper process is required for the fn key and Accessibility; the rest can be Swift, Electron, or Python.

---

## 2. Reference Behavior — Reference App (Observed)

The reference app is an Electron app with a bundled native Swift helper. The UI/orchestration lives in Electron; everything Electron cannot do (the fn key, Accessibility, key injection) lives in the helper, which Electron spawns as a child process.

**Provenance.** Findings come from two static-analysis passes, both on an owned copy, nothing executed:
1. The shipped `app.asar` main-process bundle (JavaScript), via REA JS analysis and targeted string reads.
2. The native Swift helper binary, disassembled and decompiled in Hopper (manual read).

Binary analyzed: the reference app's bundled native Swift helper (Mach-O, arm64). SHA-256 `c4c4492b7209c5d8dea19da27b77ab558301baa62f4af9486d66b18569b303e9`. The native specifics that §4–§9 depend on are now confirmed in the binary rather than inferred from the JS side; the remaining unconfirmed items are listed in §12.

| Area | Observed | Confidence |
|---|---|---|
| Process model | Swift helper spawned with `stdio: [pipe,pipe,pipe,pipe]` | Observed (JS) |
| Hotkey | Primary key handled by the helper's own CGEventTap; Electron `globalShortcut` only for Alt+K and Escape | Observed (JS) |
| Dictation mode | Dominant IPC verb is `pushToTalk` (hold-to-talk); also `hotkey`, `keyDown` | Observed (JS) |
| IPC channel | fd 3 is the dedicated channel; stdout is logging-only | Observed (JS) |
| IPC format | Separator-delimited, escaped JSON; `HelperAPIRequest` / `HelperAPIResponse`, validated against a typed schema | Observed (JS) |
| Focus/AX | Helper reports `textboxContents` and `AccessibilityStatus` to Electron | Observed (JS) |
| Paste | `clipboard.writeText(text)` then previous clipboard restored | Observed (JS) |
| Verification | AX re-read of focused field, `editDistanceToPasted`; fallback notification if not editable | Observed (JS) |
| Transcription | Cloud: PCM audio to `/v1/meetings/`, `/v1/folders/`. We replace this with local whisper.cpp | Observed (JS) |
| Permissions | Ships `FlowPermissionGuide.app`; opens `systempreferences:` panes; mic via `askForMediaAccess` | Observed (JS) |
| Sounds | Versioned sets (v7–v12): `dictation-start`, `dictation-stop`, `paste`, `popo-lock` | Observed (JS) |
| **fn detection (native)** | **Keyboard CGEventTap, mask `0x6001c00` (keyDown + keyUp + flagsChanged); fn read via `CGEventGetFlags` bit 23 + keycode `0x3f`** | **Confirmed (Hopper)** |
| **Consume behavior (native)** | **Keyboard tap is a default (consuming) tap; conditionally returns NULL to swallow keys. Mouse tap is ListenOnly** | **Confirmed (Hopper)** |
| **Permission preflight (native)** | **`AXIsProcessTrusted` + `CGPreflightListenEventAccess` + `CGPreflightPostEventAccess` at keyboard-service startup** | **Confirmed (Hopper)** |
| **Focused-field read (native)** | **`AXUIElementCreateSystemWide` + `CopyAttributeValue`, plus positional and parameterized reads** | **Confirmed (Hopper, imports)** |

---

## 3. Target Architecture

Two processes: a native helper owns the fn key, ⌘V injection, and Accessibility reads; the orchestrator runs the local ML pipeline (capture → whisper.cpp → cleanup) and the clipboard. They talk over the fd-3 channel (§6). Build it all in one native process and the IPC collapses to in-process calls.

---

## 4. fn Push-to-Talk Hotkey

The fn key must be captured by a native `CGEventTap` in a helper process, not by Electron. Electron's `globalShortcut` cannot register fn at all, which is why the reference app's primary key lives in its Swift helper and `globalShortcut` is reserved for ordinary combos (Alt+K, Escape).

**Mechanism (as confirmed in the reference app's helper)**
1. Create a session-level `CGEventTap` at head-insert position. The reference app's call is `CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, options, 0x6001c00, callback, ctx)`.
2. The mask `0x6001c00` selects **keyDown (bit 10), keyUp (bit 11), and flagsChanged (bit 12)**, plus two higher bits (25, 26) whose purpose is not confirmed. The fn (Globe) key surfaces as a flagsChanged event.
3. In the callback's processing path, the reference app reads the modifier flags with `CGEventGetFlags`, then extracts **bit 23 (`kCGEventFlagMaskSecondaryFn`)** with a bitfield-extract (`ubfx x, flags, #23, #1`). It also reads the keycode via `CGEventGetIntegerValueField(event, 9)` and matches the fn keycode **`0x3f` (63)**. So it detects fn two ways: by flag bit and by keycode.
4. On down → start dictation; on up → stop. Hold-to-talk (the reference app's `pushToTalk`). Also support a tap-to-toggle / hands-free lock mode (§10).
5. Forward each transition to the orchestrator over the IPC channel (§6).

**Consume vs observe (confirmed).** The reference app runs two separate taps with different intents:
- The **mouse "click tap"** is created ListenOnly (`options = 0x1`), mask `0x2` (left-mouse-down only). It only observes.
- The **keyboard tap** is created in **default mode (`options = 0x0`), which is consuming-capable**, and it does conditionally consume. Its callback decides per-event whether to return the event (pass through) or return **NULL (swallow)**. This is how it hides the activation key and dictated keystrokes from the focused app. The ListenOnly variants that appear in the keyboard setup are throwaway probe taps used to test whether access is granted, then immediately invalidated.

**Requirements & gotchas**
- An event tap requires Accessibility permission (§5) even to receive events. Without it the tap is created but receives nothing.
- Decide whether to consume fn or pass it through. fn also drives media/brightness and emoji; consuming it globally is hostile. The reference app's model is the pragmatic answer: run a consuming-capable tap but return NULL only for the keys you actually own, and pass everything else through. Prefer consuming only while actively dictating or only for the activation key itself.
- The OS disables a tap that is slow or times out (`kCGEventTapDisabledByTimeout`). Handle that event and re-enable the tap (§12, Q6).
- Keep the callback non-blocking. The reference app's callback hands off immediately and even watchdogs itself: it times each dispatch with `CFAbsoluteTimeGetCurrent` and logs when processing exceeds ~0.25s, because a slow callback is exactly what trips the timeout disable.
- fn can be remapped by the user (System Settings → Keyboard). Offer an alternate trigger key as a fallback.

---

## 5. Permissions (Accessibility & Microphone)

Two separate TCC permissions are required, requested at different moments. The reference app's helper preflights **three** CoreGraphics/AX checks at keyboard-service startup, confirmed in the binary: `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()` (Input Monitoring / listen), and `CGPreflightPostEventAccess()` (permission to inject events). It assembles a status object keyed `accessibilityTrusted`, `listenEventAccess`, `postEventAccess` and reports it up to the UI.

| Permission | Needed for | API | When to ask |
|---|---|---|---|
| Accessibility | The event tap (fn), reading the focused field, synthesizing ⌘V | `AXIsProcessTrusted()`; prompt via `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | At first run, before arming the tap |
| Input Monitoring | Receiving key events on the tap | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` | Alongside Accessibility, before arming the tap |
| Post-event access | Injecting synthetic keystrokes (⌘V) | `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` | Before first injection |
| Microphone | Recording audio | `AVCaptureDevice.requestAccess(for: .audio)` | First time the user dictates |

**Guided flow.** Accessibility cannot be granted programmatically; the user must toggle it in System Settings. The reference app ships a whole `FlowPermissionGuide.app` for this. Mirror that:
1. On launch, check `AXIsProcessTrusted()` and the two `CGPreflight...` statuses.
2. If not trusted, show a guide window explaining why, then deep-link to the pane: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
3. Poll `AXIsProcessTrusted()` (or re-check on app re-activation) and advance the UI once granted.
4. Request microphone access lazily on first dictation, with a clear pre-prompt.

**Gotchas**
- Accessibility is keyed to the app's code signature. Re-signing or moving the bundle can silently drop the grant; the user must remove and re-add it.
- The helper and the main app may need their own entries depending on which process creates the tap and injects keys. Keep key injection and the tap in the same process to need only one grant.
- During development, unsigned rebuilds reset the grant often; expect to re-add it.

---

## 6. Main ↔ Helper IPC Protocol

The reference app keeps control messages off stdout. The helper is spawned with four pipes (`stdio: [pipe, pipe, pipe, pipe]`) and fd 3 carries all IPC; stdout/stderr are logging only. Adopt the same split so log noise never corrupts the message stream.

**Framing (observed in JS; byte-level detail not yet confirmed in the binary, see §12 Q7):** messages are separator-delimited and escaped, each a JSON object, parsed and validated against a typed schema. Two shapes travel the wire: `HelperAPIRequest` and `HelperAPIResponse`, a request/response RPC in both directions.

**Message types to implement** (names mirror the reference app's observed vocabulary):

| Direction | Message | Payload | Purpose |
|---|---|---|---|
| helper → main | `hotkey` / `keyDown` | key id, down/up | fn transitions |
| helper → main | `pushToTalk` | state (start/stop) | hold-to-talk lifecycle |
| main → helper | request `textboxContents` | — | read focused field (editability, text, selection) |
| helper → main | response `textboxContents` | text, isEditable, flags | focus snapshot for verification |
| main → helper | request paste/inject | text or "press ⌘V" | insert the result |
| helper → main | `AccessibilityStatus` | trusted/listen/post bools | permission state changes |

**Design notes**
- Pick a concrete separator (newline or NUL) and escape it in payloads; accumulate partial chunks and split on the delimiter (the reference app buffers `pendingData` and splits).
- Give each request an id so responses can be matched; time out unanswered requests.
- Validate every inbound message against a schema and reject malformed input. The helper runs with Accessibility privileges, so treat the boundary as a trust boundary.
- If you build the whole app in one language (e.g. Swift menu-bar app), this becomes in-process calls and the pipe protocol is unnecessary; the two-process split is only needed when the orchestrator (Electron/Python) cannot host the native tap itself.

---

## 7. Audio Capture & Local Transcription

This is where our app diverges from the reference app: transcription runs on-device via whisper.cpp instead of a cloud endpoint. There is no network call and no per-word limit.

**Capture**
- Start capture on dictation-start, stop on dictation-stop.
- Record mono 16 kHz PCM (whisper's native rate) via AVAudioEngine, or capture at the device rate and downsample. The reference app also moves audio as PCM.
- Buffer frames in memory; a hold-to-talk clip is short, so no disk spill is needed.

**Transcription**
- Feed the captured PCM to whisper.cpp. Two options:
  - One-shot: transcribe the whole clip on key-up. Simplest; latency = model time after you stop talking.
  - Streaming: feed rolling chunks during the hold so the result is nearly ready at key-up. Lower perceived latency, more complexity.
- Model choice (Apple Silicon): large-v3-turbo (best accuracy, ~1s on M-series for short clips) or a small/base English model for lowest latency. Make it configurable.
- Enable Metal/Core ML acceleration in the whisper.cpp build.

**Targets**
- End-to-end (key-up → text ready) under ~1–1.5s for a sentence on Apple Silicon.
- Graceful handling of empty/near-silent clips (skip paste, play no sound).

**Output:** plain transcript text handed to the cleanup stage (§8), then to insertion (§9).

---

## 8. Text Cleanup (Local LLM)

An optional stage that turns raw transcript into polished text, entirely on-device (Ollama or llama.cpp with a small instruct model). Keep it fast and skippable.

**What it does**
- Remove fillers (um, uh, like), false starts, and repeated words.
- Fix capitalization and punctuation.
- Optionally apply light formatting to spoken commands ("new line", "bullet point").

**Prompt shape**
- System: "You clean up dictated text. Fix punctuation, capitalization, and remove fillers and false starts. Preserve the speaker's meaning and wording. Output only the cleaned text, nothing else."
- User: the raw transcript.
- Constrain output (low temperature, stop sequences) so it never adds commentary.

**When to run**
- After transcription, before insertion.
- Gate on length/latency: for very short clips, cleanup may be skippable. Make it a toggle.
- Budget: a small model should clean a sentence in a few hundred ms on Apple Silicon; if it exceeds a timeout, fall back to the raw transcript rather than block the paste.

**Risk:** an LLM can rewrite meaning or hallucinate. Prefer a conservative prompt and a small, instruction-following model; always keep the raw transcript as the fallback.

---

## 9. Text Insertion / Paste

The reference app inserts via the clipboard, then restores what was there. Mirror that; it is the most compatible way to get text into an arbitrary app. The helper imports both a synthetic-paste path and a direct-AX-write path (see §12 Q4), so the clipboard+⌘V sequence below is the primary route with AX-set as an alternative.

**Sequence (observed in the reference app, adopt as-is)**
1. Save the current clipboard contents.
2. `clipboard.writeText(finalText)`.
3. Synthesize ⌘V into the focused app (native key injection via CGEvent).
4. Restore the saved clipboard after a short delay.

**Verification (the reference app's "content observation")**
- Before/after, read the focused element's text via Accessibility (AXUIElement).
- Compare observed text to what was pasted (`editDistanceToPasted`) to confirm it landed.
- If the field is not editable or no text box is found, skip the paste and surface a notification instead of silently failing.

**Gotchas**
- Restore timing: paste too fast and ⌘V may fire before the clipboard write is visible; restore too fast and you clobber the paste. Use a small delay and/or confirm via observation.
- Secure fields (password inputs) and some sandboxed apps block synthetic paste; detect and degrade gracefully.
- Preserve the user's clipboard format if you can (not just plain text), or at least restore plain text faithfully.
- An alternative is direct AX insertion (`AXUIElementSetAttributeValue` on `kAXValueAttribute` / selected text), which the reference app's helper also links. It is less universally supported than ⌘V; clipboard+⌘V is the pragmatic default.

---

## 10. UX States, Sounds & Overlay

The reference app's asset set reveals its interaction model: sounds named `dictation-start`, `dictation-stop`, `paste`, and `popo-lock`, plus a status window and overlays. Mirror the feedback, which is what makes dictation feel responsive.

**States**
1. Idle — listening for the hotkey.
2. Recording — fn held; show an indicator, play `dictation-start`.
3. Transcribing — fn released; brief spinner.
4. Pasting — play `paste`; text inserted.
5. Locked / hands-free — tap-to-toggle mode so the user need not hold fn; `popo-lock` marks entering it.

**Audio cues**
- Short start/stop/paste sounds give feedback without a visible window. Keep them subtle and let the user mute them.

**Overlay / indicator**
- A small always-on-top, non-activating panel near the cursor or in a fixed corner showing record/transcribe state. On macOS use a borderless NSPanel that does not steal focus (critical; stealing focus breaks the paste target).
- Optionally show a live partial transcript while streaming.

**Menu-bar item**
- Status, toggle, model picker, permission shortcuts, quit.

---

## 11. Permissions, Entitlements & Packaging

**Info.plist usage strings**
- `NSMicrophoneUsageDescription` — required or the mic request crashes.
- No usage string exists for Accessibility; it is granted in System Settings, not via a plist key.

**Signing & hardened runtime**
- Sign with a stable Developer ID. The Accessibility grant is bound to the signature, so a consistent identity avoids users re-granting after every update.
- Hardened runtime with the audio-input entitlement for the mic.
- If sandboxed, note that global event taps and arbitrary key injection are generally incompatible with the App Sandbox; a dictation tool like this ships Developer ID / notarized outside the Mac App Store.

**Process/bundle layout**
- Keep the CGEventTap and the ⌘V injection in one native process so a single Accessibility grant covers both.
- If using Electron/Python as the orchestrator, bundle the native helper inside the app (under `Resources/`), spawn it with the fd-3 pipe, and supervise/restart it on crash.

**Distribution**
- Notarize for Gatekeeper. whisper.cpp model files are large; download on first run or ship a small default model and offer larger ones as optional downloads.

---

## 12. Native Helper — Confirmed Findings & Remaining Questions

Status of the seven questions after the manual Hopper read of the Swift helper. Five are confirmed, one is localized to a named function pending one more read, one is not started. These confirmations are for interoperability/learning on an owned copy. None of it uses the reference app's cloud API, which we are not replicating.

| # | Question | Status | Evidence |
|---|---|---|---|
| 1 | Exact fn detection | **Confirmed** | Keyboard tap mask `0x6001c00` includes flagsChanged (bit 12). In `sub_1002ad39c`: fn flag read via `CGEventGetFlags` then `ubfx x8, flags, #23, #1` (bit 23 = `kCGEventFlagMaskSecondaryFn`); keycode read via `CGEventGetIntegerValueField(event, 9)` and matched against `0x3f` (fn/Globe = 63). Event-type branch on `0xc` (flagsChanged) and `0xa` (keyDown). |
| 2 | Consume fn or observe only? | **Confirmed** | Two taps. Mouse "click tap" (`sub_10004cb5c`) = ListenOnly (`options 0x1`), mask `0x2`, observe only. Keyboard tap (`sub_1002ae444`) created default/consuming (`options 0x0`); dispatcher `sub_1002ad39c` conditionally sets `event = NULL` and returns it (swallow) based on decision fn `sub_1002ad724`, else retains and passes the event through. Returning NULL is the confirmed consume mechanism. ListenOnly keyboard taps that appear are throwaway permission probes, invalidated immediately. |
| 3 | Accessibility prompt | **Confirmed** | Keyboard service preflights `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, `CGPreflightPostEventAccess()` at startup; builds a status object keyed `accessibilityTrusted` / `listenEventAccess` / `postEventAccess`. Prompt path via `AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt` present in imports. |
| 4 | Key injection method | **Open (capabilities confirmed, selection logic not read)** | Imports confirm all paths: `CGEventCreateKeyboardEvent` + `CGEventSetFlags` + `CGEventPost`, plus pid-targeted `CGEventPostToPid`, plus non-synthetic `AXUIElementSetAttributeValue`. Also `CGPreflightPostEventAccess` corroborates injection. Open: read `CGEventCreateKeyboardEvent` callers to see the ⌘V keycode (`0x09` + Command flag `0x100000`), whether it posts globally or to a pid, and the branch that chooses synthetic-paste vs AX-set. |
| 5 | Focused-field read | **Confirmed** | Imports `AXUIElementCreateSystemWide` + `AXUIElementCopyAttributeValue` (focused-element read), plus `AXUIElementCopyElementAtPosition` (positional hit-test) and `AXUIElementCopyParameterizedAttributeValue` (range/selection reads). |
| 6 | Tap re-enable after timeout | **Localized, one read to confirm** | Initial `CGEventTapEnable(tap, 1)` confirmed after runloop-add in both tap setups. The disabled-notification handling is at the top of `sub_1002ad39c`: event type `-1` (`kCGEventTapDisabledByUserInput`) and `-2` (`kCGEventTapDisabledByTimeout`) both route to `sub_1002ab460`. Confirm `sub_1002ab460` calls `CGEventTapEnable(tap, 1)` to re-arm. `sub_1001af0e0` also calls `CGEventTapEnable` twice and is a secondary candidate. |
| 7 | fd-3 framing details | **Not started** | Exact delimiter byte and escape scheme on the IPC pipe. Read `write`/`writev`/`FileHandle` callers where the fd is literal `3`; inspect the buffer assembled just before the write. The hardest remaining item; do last. |

**Function map (Swift helper, for re-navigation)**

| Role | Address / label |
|---|---|
| Keyboard service setup ("Starting run loop in keyboard service") | `sub_1002ae444` |
| Keyboard tap callback (thin dispatcher + latency watchdog) | `sub_1002aea60` |
| Keyboard event processing (fn flag + keycode + consume decision) | `sub_1002ad39c` |
| Consume-decision fn (returns true → swallow key) | `sub_1002ad724` |
| Tap-disabled (-1/-2) handler (Q6 re-enable candidate) | `sub_1002ab460` |
| Latency watchdog (fires when dispatch > ~0.25s) | `sub_1002a9544` |
| Mouse "click tap" setup (DropWitness) | `sub_10004cb5c` (callback `sub_10004cfcc`) |
| Sibling mouse tap-setup helper | `sub_10004cb8c` |
| Telemetry/log sink (category tags "keyboard", "mouse") | `sub_1002abb84` |
| Binary SHA-256 | `c4c4492b7209c5d8dea19da27b77ab558301baa62f4af9486d66b18569b303e9` |

**Observed design notes worth carrying into our build**
- The reference app runs multiple independent taps (at least a mouse tap and a keyboard tap) rather than one combined tap. Our app only needs the keyboard tap.
- The keyboard callback is deliberately thin: dispatch, time it, return. All real logic is one call deeper. Keep our callback equally cheap to avoid tripping the OS timeout disable.
- The consume decision is per-key, not global. The tap is consuming-capable but passes most events through, swallowing only the keys it owns. This is the right model for not breaking fn's other roles.

**To resolve the two remaining items in Hopper:** `Cmd+G` to `sub_1002ab460` (Q6), then to the callers of `CGEventCreateKeyboardEvent` (Q4), then trace `write`/`FileHandle` with fd `3` (Q7). The demo build only blocks Python scripting, so manual GUI reads are unaffected; the REA/agent path needs a licensed Hopper or a switch to a scriptable backend (Ghidra/radare2).

---

## 13. Build Milestones & Acceptance Criteria

Build in thin vertical slices; each phase has one testable check before moving on.

| Phase | Goal | Acceptance check |
|---|---|---|
| 0 | Permissions + event tap | App requests Accessibility + Input Monitoring; a CGEventTap logs fn down/up globally |
| 1 | Hotkey echo | Holding fn prints start/stop to the console reliably across apps |
| 2 | Audio capture | fn-hold records 16 kHz mono PCM; clip saved/inspectable on release |
| 3 | Local transcription | whisper.cpp returns correct text for a spoken clip; latency measured |
| 4 | Insertion | Transcript pastes into any focused editable field; old clipboard restored |
| 5 | Cleanup LLM | Local model removes fillers/fixes punctuation; raw-transcript fallback on timeout |
| 6 | UX polish | Overlay + start/stop/paste sounds; menu-bar control; hands-free lock mode |
| 7 | Hardening | Tap re-enables after timeout; non-editable/secure fields degrade gracefully; signed & notarized |

**Definition of done:** hold fn anywhere, speak, release, and cleaned text appears at the cursor in under ~1.5s, fully offline, with the prior clipboard intact. No account, no network, no limit.

**Suggested stack:** a native Swift menu-bar app keeps the tap, injection, and AX in one signed process and avoids the IPC pipe entirely. Choose Electron/Python only if you want that UI layer, in which case replicate the fd-3 helper split from §6.
