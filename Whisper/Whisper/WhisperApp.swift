import SwiftUI
import AppKit
import AVFoundation
import WhisperKit
import os.log

private let appLogger = Logger(subsystem: "soli.whisper.Whisper", category: "app")
let minRecordSeconds = 0.3
let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dictate_transcripts", isDirectory: true)

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private var whisperKit: WhisperKit?
    private var isRecording = false
    private var isTranscribing = false
    private var flagsMonitor: Any?
    private var overlay: OverlayWindow?
    private var rightOptionDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupHotkeyMonitor()
        overlay = OverlayWindow()
        Task { await loadWhisperModel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(.loading)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func setupHotkeyMonitor() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isRightOption = event.keyCode == 61
        guard isRightOption else { return }

        let optionPressed = event.modifierFlags.contains(.option)
        if optionPressed && !rightOptionDown {
            rightOptionDown = true
            if !isRecording && !isTranscribing { startRecording() }
        } else if !optionPressed && rightOptionDown {
            rightOptionDown = false
            if isRecording { stopRecording() }
        }
    }

    private func loadWhisperModel() async {
        appLogger.info("Loading Whisper model...")
        do {
            whisperKit = try await WhisperKit(model: "large-v3")
            appLogger.info("Whisper model loaded")
            updateIcon(.ready)
        } catch {
            appLogger.error("Failed to load Whisper model: \(error.localizedDescription)")
            showNotification(title: "Whisper", message: "Failed to load model: \(error.localizedDescription)")
        }
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recorder.start()
        isRecording = true
        updateIcon(.recording)
        statusItem.menu?.item(at: 0)?.title = "Stop Recording"
        overlay?.showRecording()
        appLogger.info("Recording started")
    }

    private func stopRecording() {
        let samples = recorder.stop()
        isRecording = false
        updateIcon(.ready)
        statusItem.menu?.item(at: 0)?.title = "Start Recording"
        appLogger.info("Recording stopped, samples: \(samples.count)")

        guard !samples.isEmpty else {
            appLogger.info("No audio captured")
            overlay?.hide()
            return
        }

        let duration = Double(samples.count) / recorder.sampleRate
        appLogger.info("Audio duration: \(String(format: "%.2f", duration))s")

        if duration < minRecordSeconds {
            appLogger.info("Audio too short")
            overlay?.hide()
            showNotification(title: "Whisper", message: "Recording too short. Hold Right Option longer.")
            return
        }

        isTranscribing = true
        overlay?.showTranscribing()

        Task {
            await transcribe(samples: samples)
        }
    }

    private func transcribe(samples: [Float]) async {
        guard let whisperKit else {
            appLogger.error("WhisperKit not initialized")
            overlay?.hide()
            isTranscribing = false
            return
        }

        do {
            let resampled = resampleTo16kHz(samples: samples, fromRate: recorder.sampleRate)
            let results = try await whisperKit.transcribe(audioArray: resampled)
            let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

            appLogger.info("Transcription: \(text.prefix(100))...")

            if text.isEmpty {
                showNotification(title: "Whisper", message: "No speech detected. Try again.")
            } else {
                saveTranscript(text)
                copyAndPaste(text)
            }
        } catch {
            appLogger.error("Transcription failed: \(error.localizedDescription)")
            showNotification(title: "Whisper", message: "Transcription failed: \(error.localizedDescription)")
        }

        overlay?.hide()
        isTranscribing = false
    }

    private func resampleTo16kHz(samples: [Float], fromRate: Double) -> [Float] {
        guard fromRate != 16000 else { return samples }
        let ratio = 16000.0 / fromRate
        let newCount = Int(Double(samples.count) * ratio)
        return (0..<newCount).map { i in
            let srcIndex = Double(i) / ratio
            let lower = Int(srcIndex)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(srcIndex - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private func saveTranscript(_ text: String) {
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let path = transcriptsDir.appendingPathComponent("\(formatter.string(from: Date())).txt")
        try? text.write(to: path, atomically: true, encoding: .utf8)
        appLogger.info("Saved transcript to \(path.path)")
    }

    private func copyAndPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        let success = pb.setString(text, forType: .string)
        appLogger.info("Clipboard write success: \(success)")

        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            showNotification(title: "Whisper", message: "Grant Accessibility permission, then try again. Text is in clipboard.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.simulatePaste()
        }
    }

    private func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        appLogger.info("Paste sent")
    }


    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    private enum IconState { case loading, ready, recording }

    private func updateIcon(_ state: IconState) {
        let name: String
        switch state {
        case .loading: name = "ellipsis.circle"
        case .ready: name = "mic"
        case .recording: name = "waveform"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private(set) var sampleRate: Double = 16000
    private var samples: [Float] = []
    private let lock = NSLock()

    func start() {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
            self.lock.unlock()
        }

        engine.prepare()
        try? engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        let result = samples
        lock.unlock()
        return result
    }
}

@MainActor
final class OverlayWindow {
    private let window: NSWindow
    private let label: NSTextField

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 42, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = true

        let vibrancy = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
        vibrancy.material = .hudWindow
        vibrancy.state = .active
        vibrancy.blendingMode = .behindWindow
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = 10
        vibrancy.layer?.masksToBounds = true

        label = NSTextField(labelWithString: "🎙️")
        label.font = NSFont.systemFont(ofSize: 22)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 6, width: 42, height: 30)

        vibrancy.addSubview(label)
        window.contentView = vibrancy
    }

    func showRecording() {
        label.stringValue = "🎙️"
        let pos = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pos.x + 4, y: pos.y - 46))
        window.orderFront(nil)
    }

    func showTranscribing() {
        label.stringValue = "⏳"
    }

    func hide() {
        window.orderOut(nil)
    }
}
