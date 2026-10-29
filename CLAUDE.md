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