# Local Dictation App

Full build spec: docs/BUILD_SPEC.md — read it before starting any phase.

## Hard rules
- Build in the phases from spec §13, in order. Do not start a phase until the
  previous phase's acceptance check passes.
- Fully local. No network calls, no cloud transcription, no account. whisper.cpp
  on-device only.
- Keep the CGEventTap and key injection in one native process (single
  Accessibility grant).
- Do not claim a phase is done until I have confirmed its acceptance check on my
  machine. Permission grants and the event tap cannot be verified in your
  sandbox — they need me to grant Accessibility/Input Monitoring and run it.

## Stack
- Native Swift menu-bar app (spec §13 "Suggested stack"). One process owns the event tap, ⌘V injection, and Accessibility reads, so the §6 helper IPC protocol is out of scope.
- Swift Package Manager layout: a `DictationCore` library holds all logic and is tested with `swift test`; the app target is a thin shell over it.
- Cleanup LLM runs in-process via llama.cpp from a model file on disk. No localhost server, no model downloads at runtime.

## Workflow
- Test-driven development on every ticket: write a test for one acceptance criterion, run it and confirm it fails, then write the minimum code to pass it. No production code without a failing test first.
- Every OS or hardware boundary (CGEventTap, AXIsProcessTrusted, AXUIElement, AVAudioEngine, NSPasteboard, CGEvent posting, whisper.cpp, llama.cpp) sits behind a Swift protocol. Tests use fakes; only a thin adapter touches the real API. Tests must never need a microphone, a permission grant, or a model file, so they pass in CI.
- Anything that needs a real permission grant, a real fn press, a real microphone, or a real paste into another app is a manual check. List the exact steps for me and leave it unchecked.
- One ticket per branch, one pull request per ticket. Never merge or close an issue until I confirm the manual checks on my machine.
- Spec §2 and §12 (Wispr reference behavior and Hopper questions) are background only. Never create tickets or code from them.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `AlexD4110/XFlow`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The seven canonical triage roles, each mapped to a label of the same name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `GLOSSARY.md`, ADRs in `docs/adr/`. See `docs/agents/domain.md`.

### External peers

`auto` — select the hardened Claude or Codex adapter from host metadata. See `docs/agents/cross-model.json`.