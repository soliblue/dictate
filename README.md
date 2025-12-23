# Dictate

Voice-to-text dictation for macOS. Hold Right Option to record, release to transcribe and paste.

## Whisper (Native Swift App)

Production-ready menu bar app using WhisperKit (large-v3 model).

```
Whisper/
├── Whisper.xcodeproj
└── Whisper/
    └── WhisperApp.swift
```

**Run:** Open `Whisper/Whisper.xcodeproj` in Xcode → Run (⌘R)

**First launch:** Downloads model (~1.5GB), grant Microphone + Accessibility permissions.

## python/ (Prototype)

Original Python prototype using MLX Whisper.

```bash
cd python
source .venv/bin/activate && python dictate.py
```
