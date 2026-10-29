import DictationCore

// The app target is a thin shell: it hands control straight to DictationCore,
// which owns the event tap, key injection, and Accessibility reads in one
// process. All logic lives in DictationCore so it can be tested without the app.
DictationCore.launch()
