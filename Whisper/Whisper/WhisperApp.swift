import SwiftUI
import AppKit
import AVFoundation
import WhisperKit
import Quartz
import UserNotifications

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

let minRecordSeconds = 0.3

let supportedLanguages: [(code: String?, name: String)] = [
    (nil, "Auto-detect"),
    ("en", "English"),
    ("de", "German"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("nl", "Dutch"),
    ("pl", "Polish"),
    ("ru", "Russian"),
    ("zh", "Chinese"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("ar", "Arabic")
]

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct TranscriptionQueueItem {
    let samples: [Float]
    let sampleRate: Double
    let savedWindow: AXUIElement?
    let savedAppPid: pid_t
    let savedWindowId: CGWindowID
    let savedWindowTitle: String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private var whisperKit: WhisperKit?
    private var isRecording = false
    private var isTranscribing = false
    private var flagsMonitor: Any?
    private var screenGlow: ScreenGlow?
    private var launcherPanel: LauncherPanel?
    private var statusMenu: NSMenu?
    private var rightOptionDown = false
    private var iconAnimationTimer: Timer?
    private var iconAnimationFrame: Int = 0
    private var transcriptionQueue: [TranscriptionQueueItem] = []
    private var chunkTimer: Timer?
    private var lastChunkEndSample: Int = 0
    private var accumulatedTranscription: String = ""
    private var isChunkTranscribing = false
    private let chunkDurationSeconds: Double = 5.0
    private let overlapDurationSeconds: Double = 1.5
    private var recordingSessionId: Int = 0
    private var selectedLanguage: String? {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: "selectedLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedLanguage")
            }
            updateLanguageMenu()
        }
    }
    private var languageMenu: NSMenu?
    private var recentMenu: NSMenu?
    private var recentTranscriptions: [TranscriptionRecord] = []
    private let transcriptionStore = TranscriptionStore()
    private var autoSendMenuItem: NSMenuItem?
    private var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSend") }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoSend")
            autoSendMenuItem?.state = newValue ? .on : .off
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        setupStatusItem()
        setupHotkeyMonitor()
        screenGlow = ScreenGlow()
        launcherPanel = LauncherPanel { [weak self] in self?.startRecording() }
        launcherPanel?.showLoading()
        Task { await loadWhisperModel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(.loading)

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }

        statusMenu = NSMenu()
        statusMenu?.addItem(NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: ""))
        statusMenu?.addItem(NSMenuItem.separator())

        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageMenu = NSMenu()
        for lang in supportedLanguages {
            let item = NSMenuItem(title: lang.name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.code
            languageMenu?.addItem(item)
        }
        langItem.submenu = languageMenu
        statusMenu?.addItem(langItem)
        updateLanguageMenu()

        let recentItem = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        recentMenu = NSMenu()
        recentItem.submenu = recentMenu
        statusMenu?.addItem(recentItem)
        loadRecentTranscriptions()

        autoSendMenuItem = NSMenuItem(title: "Auto-Send (Press Enter)", action: #selector(toggleAutoSend), keyEquivalent: "")
        autoSendMenuItem?.target = self
        autoSendMenuItem?.state = autoSend ? .on : .off
        statusMenu?.addItem(autoSendMenuItem!)

        statusMenu?.addItem(NSMenuItem.separator())
        statusMenu?.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusMenu?.items.forEach { $0.target = self }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.modifierFlags.contains(.option) || event.type == .rightMouseUp {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            launcherPanel?.updateStats(transcriptionCount: totalTranscriptionCount(), recentTexts: recentTranscriptions.map { $0.text })
            launcherPanel?.toggle()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        selectedLanguage = sender.representedObject as? String
    }

    @objc private func toggleAutoSend() {
        autoSend = !autoSend
    }

    private func updateLanguageMenu() {
        languageMenu?.items.forEach { item in
            let code = item.representedObject as? String
            item.state = (code == selectedLanguage) ? .on : .off
        }
    }

    private func totalTranscriptionCount() -> Int {
        transcriptionStore.count()
    }

    private func loadRecentTranscriptions() {
        recentTranscriptions = transcriptionStore.loadAll()
        updateRecentMenu()
    }

    private func updateRecentMenu() {
        recentMenu?.removeAllItems()
        if recentTranscriptions.isEmpty {
            recentMenu?.addItem(NSMenuItem(title: "No transcriptions yet", action: nil, keyEquivalent: ""))
            return
        }
        for record in recentTranscriptions.prefix(5) {
            var preview = record.text.replacingOccurrences(of: "\n", with: " ")
            if preview.count > 50 { preview = String(preview.prefix(50)) + "..." }
            let item = NSMenuItem(title: preview, action: #selector(copyTranscription(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = record.text
            recentMenu?.addItem(item)
        }
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        showNotification(title: "Whisper", message: "Copied to clipboard!")
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
            if !isRecording { startRecording() }
        } else if !optionPressed && rightOptionDown {
            rightOptionDown = false
            if isRecording { stopRecording() }
        }
    }

    private func loadWhisperModel() async {
        do {
            whisperKit = try await WhisperKit(model: "large-v3")
            updateIcon(.ready)
            launcherPanel?.hideLoading()
        } catch {
            showNotification(title: "Whisper", message: "Failed to load model: \(error.localizedDescription)")
            launcherPanel?.hideLoading()
        }
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        logFocusInfo()
        recorder.start()
        isRecording = true
        recordingSessionId += 1
        lastChunkEndSample = 0
        accumulatedTranscription = ""
        isChunkTranscribing = false
        updateIcon(.recording)
        statusItem.menu?.item(at: 0)?.title = "Stop Recording"
        screenGlow?.show(mode: .recording)
        launcherPanel?.showRecording()
        startChunkTimer()
    }

    private func startChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDurationSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.transcribeCurrentChunk()
            }
        }
    }

    private func transcribeCurrentChunk() {
        guard isRecording, !isChunkTranscribing, let whisperKit else { return }

        let sampleRate = recorder.sampleRate
        let chunkSamples = Int(chunkDurationSeconds * sampleRate)
        let overlapSamples = Int(overlapDurationSeconds * sampleRate)
        let currentSampleCount = recorder.sampleCount()

        guard currentSampleCount >= chunkSamples else { return }

        let startSample = max(0, lastChunkEndSample - overlapSamples)
        let samples = recorder.currentSamples()
        guard startSample < samples.count else { return }

        let chunkToTranscribe = Array(samples[startSample...])
        lastChunkEndSample = samples.count

        isChunkTranscribing = true
        let sessionId = recordingSessionId
        Task {
            do {
                let resampled = AudioProcessor.resampleTo16kHz(samples: chunkToTranscribe, fromRate: sampleRate)
                var options = DecodingOptions(language: selectedLanguage)
                options.verbose = false
                let results = try await whisperKit.transcribe(audioArray: resampled, decodeOptions: options)
                let chunkText = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

                await MainActor.run {
                    guard sessionId == recordingSessionId else { return }
                    if !chunkText.isEmpty {
                        accumulatedTranscription = mergeTranscriptions(existing: accumulatedTranscription, new: chunkText)
                        launcherPanel?.updateLiveText(accumulatedTranscription)
                    }
                    isChunkTranscribing = false
                }
            } catch {
                await MainActor.run {
                    isChunkTranscribing = false
                }
            }
        }
    }

    private func mergeTranscriptions(existing: String, new: String) -> String {
        guard !existing.isEmpty else { return new }
        guard !new.isEmpty else { return existing }

        let existingWords = existing.split(separator: " ").map(String.init)
        let newWords = new.split(separator: " ").map(String.init)

        var overlapStart = -1
        for i in 0..<min(existingWords.count, 5) {
            let existingEnd = existingWords.suffix(existingWords.count - i)
            for j in 0..<min(newWords.count, existingEnd.count) {
                if Array(existingEnd.prefix(j + 1)) == Array(newWords.prefix(j + 1)) {
                    overlapStart = i
                    break
                }
            }
            if overlapStart >= 0 { break }
        }

        if overlapStart >= 0 {
            let existingPart = existingWords.prefix(overlapStart).joined(separator: " ")
            return existingPart.isEmpty ? new : existingPart + " " + new
        }

        return existing + " " + new
    }

    private var savedWindow: AXUIElement?
    private var savedAppPid: pid_t = 0
    private var savedWindowId: CGWindowID = 0
    private var savedWindowTitle: String = ""

    private func logFocusInfo() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        savedAppPid = frontApp.processIdentifier

        let appRef = AXUIElementCreateApplication(savedAppPid)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        if result == .success, let window = focusedWindowRef {
            savedWindow = (window as! AXUIElement)
            _ = _AXUIElementGetWindow(savedWindow!, &savedWindowId)
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(savedWindow!, kAXTitleAttribute as CFString, &titleRef)
            savedWindowTitle = titleRef as? String ?? ""
        } else {
            savedWindow = nil
            savedWindowId = 0
            savedWindowTitle = ""
        }
    }

    private func windowChanged() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return true }

        if frontApp.processIdentifier != savedAppPid { return false }

        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        guard result == .success, let window = focusedWindowRef else { return false }

        var currentWindowId: CGWindowID = 0
        _ = _AXUIElementGetWindow(window as! AXUIElement, &currentWindowId)

        return currentWindowId != savedWindowId
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    private func stopRecording() {
        chunkTimer?.invalidate()
        chunkTimer = nil

        let allSamples = recorder.stop()
        let sampleRate = recorder.sampleRate
        isRecording = false
        statusItem.menu?.item(at: 0)?.title = "Start Recording"

        guard !allSamples.isEmpty else {
            accumulatedTranscription = ""
            if !isTranscribing {
                screenGlow?.hide()
                launcherPanel?.resetToIdle()
                updateIcon(.ready)
            }
            return
        }

        let duration = Double(allSamples.count) / sampleRate

        if duration < minRecordSeconds {
            accumulatedTranscription = ""
            if !isTranscribing {
                screenGlow?.hide()
                launcherPanel?.resetToIdle()
                updateIcon(.ready)
            }
            showNotification(title: "Whisper", message: "Recording too short. Hold Right Option longer.")
            return
        }

        let overlapSamples = Int(overlapDurationSeconds * sampleRate)
        let startSample = max(0, lastChunkEndSample - overlapSamples)
        let remainingSamples = startSample < allSamples.count ? Array(allSamples[startSample...]) : []

        let queueItem = TranscriptionQueueItem(
            samples: remainingSamples.isEmpty ? allSamples : remainingSamples,
            sampleRate: sampleRate,
            savedWindow: savedWindow,
            savedAppPid: savedAppPid,
            savedWindowId: savedWindowId,
            savedWindowTitle: savedWindowTitle
        )
        transcriptionQueue.append(queueItem)

        if !isTranscribing {
            processNextInQueue()
        } else {
            updateIcon(.transcribing)
            screenGlow?.show(mode: .transcribing)
            launcherPanel?.showTranscribing()
        }
    }

    private func processNextInQueue() {
        guard !transcriptionQueue.isEmpty else {
            isTranscribing = false
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            updateIcon(.ready)
            return
        }

        let item = transcriptionQueue.removeFirst()
        isTranscribing = true
        updateIcon(.transcribing)
        screenGlow?.show(mode: .transcribing)
        launcherPanel?.showTranscribing()

        Task {
            await transcribe(item: item)
        }
    }

    private func transcribe(item: TranscriptionQueueItem) async {
        guard let whisperKit else {
            processNextInQueue()
            return
        }

        do {
            let resampled = AudioProcessor.resampleTo16kHz(samples: item.samples, fromRate: item.sampleRate)
            let options = DecodingOptions(language: selectedLanguage)

            let results = try await whisperKit.transcribe(audioArray: resampled, decodeOptions: options)
            let chunkText = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

            let finalText = mergeTranscriptions(existing: accumulatedTranscription, new: chunkText)
            accumulatedTranscription = ""

            if finalText.isEmpty {
                showNotification(title: "Whisper", message: "No speech detected. Try again.")
            } else {
                saveTranscript(finalText)
                restoreWindow(item: item)
                copyAndPaste(finalText)
            }
        } catch {
            showNotification(title: "Whisper", message: "Transcription failed: \(error.localizedDescription)")
        }

        launcherPanel?.dequeueOne()
        processNextInQueue()
    }

    private func restoreWindow(item: TranscriptionQueueItem) {
        guard let window = item.savedWindow else { return }
        guard let app = NSRunningApplication(processIdentifier: item.savedAppPid) else { return }

        app.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func saveTranscript(_ text: String) {
        transcriptionStore.save(text)
        recentTranscriptions.insert(TranscriptionRecord(timestamp: "", text: text), at: 0)
        updateRecentMenu()
    }

    private func copyAndPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)

        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            showNotification(title: "Whisper", message: "Grant Accessibility permission, then try again. Text is in clipboard.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
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

        if autoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let enterSrc = CGEventSource(stateID: .hidSystemState)
                let enterDown = CGEvent(keyboardEventSource: enterSrc, virtualKey: 36, keyDown: true)
                let enterUp = CGEvent(keyboardEventSource: enterSrc, virtualKey: 36, keyDown: false)
                enterDown?.flags = []
                enterUp?.flags = []
                enterDown?.post(tap: .cghidEventTap)
                enterUp?.post(tap: .cghidEventTap)
            }
        }
    }

    private func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private enum IconState { case loading, ready, recording, transcribing }
    private var currentIconState: IconState = .loading

    private func updateIcon(_ state: IconState) {
        iconAnimationTimer?.invalidate()
        iconAnimationTimer = nil
        currentIconState = state
        iconAnimationFrame = 0

        switch state {
        case .loading:
            animateLoading()
        case .ready:
            statusItem.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        case .recording:
            animateRecording()
        case .transcribing:
            animateTranscribing()
        }
    }

    private func animateLoading() {
        updateLoadingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateLoadingFrame()
            }
        }
    }

    private func updateLoadingFrame() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let angle = CGFloat(iconAnimationFrame * 30)
        let gearSize: CGFloat = 14
        let canvasSize = NSSize(width: 18, height: 18)
        let rotated = NSImage(size: canvasSize, flipped: false) { _ in
            let context = NSGraphicsContext.current?.cgContext
            context?.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context?.rotate(by: angle * .pi / 180)
            let gearRect = NSRect(x: -gearSize / 2, y: -gearSize / 2, width: gearSize, height: gearSize)
            baseImage.draw(in: gearRect)
            return true
        }
        rotated.isTemplate = true
        statusItem.button?.image = rotated
    }

    private func animateRecording() {
        updateRecordingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateRecordingFrame()
            }
        }
    }

    private func updateRecordingFrame() {
        let icons = ["mic", "mic.fill", "mic.fill", "mic"]
        let icon = icons[iconAnimationFrame % icons.count]
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    private func animateTranscribing() {
        updateTranscribingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.iconAnimationFrame += 1
                self.updateTranscribingFrame()
            }
        }
    }

    private func updateTranscribingFrame() {
        let icons = ["ellipsis", "ellipsis", "sparkle", "ellipsis"]
        let icon = icons[iconAnimationFrame % icons.count]
        statusItem.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
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

    func currentSamples() -> [Float] {
        lock.lock()
        let result = samples
        lock.unlock()
        return result
    }

    func sampleCount() -> Int {
        lock.lock()
        let count = samples.count
        lock.unlock()
        return count
    }
}

@MainActor
final class ScreenGlow {
    enum Mode { case recording, transcribing }

    private var window: NSWindow?
    private var glowView: GlowBorderView?
    private let recordingColor = NSColor(red: 0.6, green: 0.75, blue: 0.85, alpha: 1.0)
    private let transcribingColor = NSColor(red: 0.75, green: 0.65, blue: 0.8, alpha: 1.0)

    init() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame

        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = GlowBorderView(frame: NSRect(origin: .zero, size: frame.size))
        win.contentView = view
        window = win
        glowView = view
    }

    func show(mode: Mode) {
        let color = mode == .recording ? recordingColor : transcribingColor
        glowView?.setColor(color)

        window?.alphaValue = 0
        window?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window?.animator().alphaValue = 1
        }
        glowView?.startPulsing()
    }

    func hide() {
        glowView?.stopPulsing()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            window?.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
            }
        }
    }

    final class GlowBorderView: NSView {
        private var glowColor: NSColor = .orange
        private var pulseTimer: Timer?
        private let topRadius: CGFloat = 18
        private let bottomRadius: CGFloat = 0
        private let glowWidth: CGFloat = 8

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        func setColor(_ color: NSColor) {
            glowColor = color
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: glowWidth/2, dy: glowWidth/2)
            let path = NSBezierPath()

            path.move(to: NSPoint(x: rect.minX + topRadius, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX - topRadius, y: rect.maxY))
            path.appendArc(withCenter: NSPoint(x: rect.maxX - topRadius, y: rect.maxY - topRadius), radius: topRadius, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY + bottomRadius))
            if bottomRadius > 0 {
                path.appendArc(withCenter: NSPoint(x: rect.maxX - bottomRadius, y: rect.minY + bottomRadius), radius: bottomRadius, startAngle: 0, endAngle: -90, clockwise: true)
            }
            path.line(to: NSPoint(x: rect.minX + bottomRadius, y: rect.minY))
            if bottomRadius > 0 {
                path.appendArc(withCenter: NSPoint(x: rect.minX + bottomRadius, y: rect.minY + bottomRadius), radius: bottomRadius, startAngle: -90, endAngle: -180, clockwise: true)
            }
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - topRadius))
            path.appendArc(withCenter: NSPoint(x: rect.minX + topRadius, y: rect.maxY - topRadius), radius: topRadius, startAngle: 180, endAngle: 90, clockwise: true)
            path.close()

            path.lineWidth = glowWidth
            glowColor.withAlphaComponent(0.5).setStroke()
            path.stroke()
        }

        func startPulsing() {
            layer?.opacity = 0.7
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let layer = self.layer else { return }
                    let animation = CABasicAnimation(keyPath: "opacity")
                    animation.fromValue = 0.7
                    animation.toValue = 0.35
                    animation.duration = 1.2
                    animation.autoreverses = true
                    layer.add(animation, forKey: "pulse")
                }
            }
            pulseTimer?.fire()
        }

        func stopPulsing() {
            pulseTimer?.invalidate()
            pulseTimer = nil
            layer?.removeAllAnimations()
        }
    }
}

@MainActor
final class LauncherPanel {
    private let window: NSPanel
    private let onRecord: () -> Void
    private var eventMonitor: Any?
    private var container: NSView!
    private var glassButton: NSVisualEffectView!
    private var micIcon: NSImageView!
    private var label: NSTextField!
    private var clickButton: NSButton!
    private var statsCard: NSVisualEffectView!
    private var statsNumberLabel: NSTextField!
    private var statsDescLabel: NSTextField!
    private var statsClickButton: NSButton!
    private var transcriptionItems: [NSView] = []
    private var scrollView: NSScrollView?
    private var dismissButton: NSButton?
    private var isExpanded = false
    private var recentTexts: [String] = []
    private let buttonHeight: CGFloat = 48
    private let cardHeight: CGFloat = 80
    private let itemHeight: CGFloat = 54
    private let expandedCardWidth: CGFloat = 320
    private let maxExpandedHeight: CGFloat = 400
    private let dividerGap: CGFloat = 12
    private let padding: CGFloat = 16
    private let iconSize: CGFloat = 20
    private let spacing: CGFloat = 10
    private var animationTimer: Timer?
    private var rotationAngle: CGFloat = 0
    private var transcribeFrame: Int = 0
    private var transcriptionCount: Int = 0
    private let circleSize: CGFloat = 36
    private let circleGap: CGFloat = 8
    private var queueCircles: [NSVisualEffectView] = []
    private var queueIcons: [NSImageView] = []
    private var queueCount: Int = 0
    private var liveTextBubble: NSVisualEffectView?
    private var liveTextLabel: NSTextField?

    init(onRecord: @escaping () -> Void) {
        self.onRecord = onRecord

        label = NSTextField(labelWithString: "hold right ⌥ to dictate")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
        let cornerRadius = buttonHeight / 2
        let totalHeight = buttonHeight + dividerGap + cardHeight

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false

        container = NSView(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight))

        glassButton = NSVisualEffectView(frame: NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight))
        glassButton.material = .hudWindow
        glassButton.state = .active
        glassButton.blendingMode = .behindWindow
        glassButton.wantsLayer = true
        glassButton.layer?.cornerRadius = cornerRadius
        glassButton.layer?.masksToBounds = true
        glassButton.alphaValue = 0.6

        micIcon = NSImageView(frame: NSRect(x: padding, y: (buttonHeight - iconSize) / 2, width: iconSize, height: iconSize))
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micIcon.contentTintColor = .labelColor
        micIcon.imageScaling = .scaleProportionallyUpOrDown

        label.frame.origin = NSPoint(x: padding + iconSize + spacing, y: (buttonHeight - label.frame.height) / 2)

        clickButton = NSButton(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight))
        clickButton.title = ""
        clickButton.bezelStyle = .regularSquare
        clickButton.isBordered = false
        clickButton.isTransparent = true
        clickButton.target = self
        clickButton.action = #selector(recordClicked)

        glassButton.addSubview(micIcon)
        glassButton.addSubview(label)
        glassButton.addSubview(clickButton)

        statsNumberLabel = NSTextField(labelWithString: "0")
        statsNumberLabel.font = NSFont.systemFont(ofSize: 32, weight: .semibold)
        statsNumberLabel.textColor = .labelColor
        statsNumberLabel.backgroundColor = .clear
        statsNumberLabel.isBezeled = false
        statsNumberLabel.isEditable = false
        statsNumberLabel.alignment = .center

        statsDescLabel = NSTextField(labelWithString: "transcriptions")
        statsDescLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statsDescLabel.textColor = .secondaryLabelColor
        statsDescLabel.backgroundColor = .clear
        statsDescLabel.isBezeled = false
        statsDescLabel.isEditable = false
        statsDescLabel.alignment = .center

        statsCard = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight))
        statsCard.material = .hudWindow
        statsCard.state = .active
        statsCard.blendingMode = .behindWindow
        statsCard.wantsLayer = true
        statsCard.layer?.cornerRadius = 16
        statsCard.layer?.masksToBounds = true
        statsCard.alphaValue = 0.6
        statsCard.isHidden = true

        statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
        statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)

        statsClickButton = NSButton(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight))
        statsClickButton.title = ""
        statsClickButton.bezelStyle = .regularSquare
        statsClickButton.isBordered = false
        statsClickButton.isTransparent = true
        statsClickButton.target = self
        statsClickButton.action = #selector(statsCardClicked)

        statsCard.addSubview(statsNumberLabel)
        statsCard.addSubview(statsDescLabel)
        statsCard.addSubview(statsClickButton)

        container.addSubview(glassButton)
        container.addSubview(statsCard)
        window.contentView = container
    }

    func updateStats(transcriptionCount: Int, recentTexts: [String] = []) {
        self.transcriptionCount = transcriptionCount
        self.recentTexts = recentTexts
        statsNumberLabel.stringValue = "\(transcriptionCount)"
        isExpanded = false
        clearTranscriptionItems()
    }

    @objc private func statsCardClicked() {
        if isExpanded {
            collapseStats()
        } else {
            expandStats()
        }
    }

    private func expandStats() {
        guard !recentTexts.isEmpty else { return }
        isExpanded = true

        let contentHeight = CGFloat(recentTexts.count) * itemHeight
        let visibleHeight = min(contentHeight, maxExpandedHeight)

        statsNumberLabel.isHidden = true
        statsDescLabel.isHidden = true
        statsClickButton.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let newCardHeight = visibleHeight + 16
            let totalHeight = buttonHeight + dividerGap + newCardHeight
            window.animator().setContentSize(NSSize(width: expandedCardWidth, height: totalHeight))
            container.animator().frame = NSRect(x: 0, y: 0, width: expandedCardWidth, height: totalHeight)
            glassButton.animator().frame = NSRect(x: (expandedCardWidth - glassButton.frame.width) / 2, y: newCardHeight + dividerGap, width: glassButton.frame.width, height: buttonHeight)
            statsCard.animator().frame = NSRect(x: 0, y: 0, width: expandedCardWidth, height: newCardHeight)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.createTranscriptionItems()
            }
        }
    }

    private func collapseStats() {
        isExpanded = false
        clearTranscriptionItems()

        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            let totalHeight = buttonHeight + dividerGap + cardHeight
            window.animator().setContentSize(NSSize(width: buttonWidth, height: totalHeight))
            container.animator().frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
            glassButton.animator().frame = NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight)
            statsCard.animator().frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statsNumberLabel.isHidden = false
                self.statsDescLabel.isHidden = false
                self.statsClickButton.isHidden = false
                self.statsNumberLabel.frame = NSRect(x: 0, y: self.cardHeight - 50, width: self.statsCard.frame.width, height: 40)
                self.statsDescLabel.frame = NSRect(x: 0, y: 14, width: self.statsCard.frame.width, height: 16)
                self.statsClickButton.frame = NSRect(x: 0, y: 0, width: self.statsCard.frame.width, height: self.cardHeight)
            }
        }
    }

    private func createTranscriptionItems() {
        let inset: CGFloat = 16
        let contentHeight = CGFloat(recentTexts.count) * itemHeight
        let visibleHeight = min(contentHeight, maxExpandedHeight)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 8, width: expandedCardWidth, height: visibleHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay

        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: expandedCardWidth, height: contentHeight))

        for (index, text) in recentTexts.enumerated() {
            let y = contentHeight - CGFloat(index + 1) * itemHeight
            let itemView = NSView(frame: NSRect(x: 0, y: y, width: expandedCardWidth, height: itemHeight))
            itemView.wantsLayer = true

            let charCount = text.count
            let badgeText = "\(charCount)"
            let badge = NSTextField(labelWithString: badgeText)
            badge.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.15)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.masksToBounds = true
            badge.alignment = .center
            badge.sizeToFit()
            let badgeWidth = max(badge.frame.width + 8, 32)
            badge.frame = NSRect(x: inset, y: (itemHeight - 14) / 2, width: badgeWidth, height: 14)

            let textX = inset + badgeWidth + 8
            let preview = text.replacingOccurrences(of: "\n", with: " ")

            let textLabel = NSTextField(wrappingLabelWithString: preview)
            textLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            textLabel.textColor = .labelColor
            textLabel.backgroundColor = .clear
            textLabel.isBezeled = false
            textLabel.isEditable = false
            textLabel.isSelectable = false
            textLabel.maximumNumberOfLines = 3
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.cell?.wraps = true
            textLabel.cell?.isScrollable = false
            textLabel.preferredMaxLayoutWidth = expandedCardWidth - textX - inset
            textLabel.frame = NSRect(x: textX, y: 6, width: expandedCardWidth - textX - inset, height: itemHeight - 12)

            let copyButton = NSButton(frame: NSRect(x: 0, y: 0, width: expandedCardWidth, height: itemHeight))
            copyButton.title = ""
            copyButton.bezelStyle = .regularSquare
            copyButton.isBordered = false
            copyButton.isTransparent = true
            copyButton.target = self
            copyButton.action = #selector(copyTranscription(_:))
            copyButton.tag = index

            itemView.addSubview(badge)
            itemView.addSubview(textLabel)
            itemView.addSubview(copyButton)

            if index < recentTexts.count - 1 {
                let divider = NSView(frame: NSRect(x: inset, y: 0, width: expandedCardWidth - inset * 2, height: 0.5))
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
                itemView.addSubview(divider)
            }

            documentView.addSubview(itemView)
            transcriptionItems.append(itemView)
        }

        scroll.documentView = documentView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: contentHeight - visibleHeight))
        statsCard.addSubview(scroll)
        scrollView = scroll

        let dismiss = NSButton(frame: NSRect(x: expandedCardWidth - 32, y: visibleHeight - 16, width: 24, height: 24))
        dismiss.bezelStyle = .circular
        dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        dismiss.imagePosition = .imageOnly
        dismiss.isBordered = false
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)
        statsCard.addSubview(dismiss)
        dismissButton = dismiss

        scroll.alphaValue = 0
        dismiss.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scroll.animator().alphaValue = 1
            dismiss.animator().alphaValue = 1
        }
    }

    @objc private func dismissClicked() {
        collapseStats()
    }

    private func clearTranscriptionItems() {
        scrollView?.removeFromSuperview()
        scrollView = nil
        dismissButton?.removeFromSuperview()
        dismissButton = nil
        transcriptionItems.removeAll()
    }

    @objc private func copyTranscription(_ sender: NSButton) {
        guard sender.tag < recentTexts.count else { return }
        let text = recentTexts[sender.tag]
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
        collapseStats()
    }

    func showLoading() {
        stopAnimation()
        statsCard.isHidden = true
        label.isHidden = true
        updateGearIcon()
        resizeWindowIconOnly()
        show()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rotationAngle -= 6
                self.updateGearIcon()
            }
        }
    }

    func hideLoading() {
        stopAnimation()
        hide()
    }

    func showIdle() {
        stopAnimation()
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micIcon.contentTintColor = .labelColor
        label.isHidden = false
        label.stringValue = "hold right ⌥ to dictate"
        label.sizeToFit()
        statsCard.isHidden = false
        resizeWindow(showStats: true)
        show()
    }

    private func updateGearIcon() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let gearSize: CGFloat = 14
        let canvasSize = NSSize(width: iconSize, height: iconSize)
        let rotated = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            NSGraphicsContext.current?.cgContext.rotate(by: self.rotationAngle * .pi / 180)
            let gearRect = NSRect(x: -gearSize / 2, y: -gearSize / 2, width: gearSize, height: gearSize)
            baseImage.draw(in: gearRect)
            return true
        }
        rotated.isTemplate = true
        micIcon.image = rotated
        micIcon.contentTintColor = .secondaryLabelColor
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        rotationAngle = 0
        transcribeFrame = 0
    }

    func showRecording() {
        stopAnimation()
        hideLiveText()
        glassButton.isHidden = true
        label.isHidden = true
        statsCard.isHidden = true
        queueCount += 1
        updateQueueCircles(recording: true)
        show()
    }

    func showTranscribing() {
        stopAnimation()
        hideLiveText()
        glassButton.isHidden = true
        label.isHidden = true
        statsCard.isHidden = true
        updateQueueCircles(recording: false)
        startTranscribeAnimation()
    }

    private func startTranscribeAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcribeFrame += 1
                self.updateFirstCircleIcon()
            }
        }
    }

    private func updateFirstCircleIcon() {
        guard !queueIcons.isEmpty else { return }
        let icons = ["ellipsis", "ellipsis", "sparkle", "ellipsis"]
        let icon = icons[transcribeFrame % icons.count]
        queueIcons[0].image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        queueIcons[0].contentTintColor = .secondaryLabelColor
    }

    private func updateQueueCircles(recording: Bool) {
        clearQueueCircles()

        let circlesWidth = CGFloat(queueCount) * circleSize + CGFloat(queueCount - 1) * circleGap
        let bubbleWidth: CGFloat = 320
        let bubbleHeight: CGFloat = liveTextBubble?.frame.height ?? 0
        let bubbleSpace: CGFloat = bubbleHeight > 0 ? bubbleHeight + 8 : 0
        let windowWidth = max(circlesWidth, circleSize, bubbleHeight > 0 ? bubbleWidth : 0)
        let totalHeight = circleSize + bubbleSpace

        window.setContentSize(NSSize(width: windowWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)

        if let bubble = liveTextBubble {
            bubble.frame.origin = NSPoint(x: (windowWidth - bubbleWidth) / 2, y: 0)
        }

        let circleY = bubbleSpace
        for i in 0..<queueCount {
            let x = CGFloat(queueCount - 1 - i) * (circleSize + circleGap) + (windowWidth - circlesWidth) / 2
            let circle = NSVisualEffectView(frame: NSRect(x: x, y: circleY, width: circleSize, height: circleSize))
            circle.material = .hudWindow
            circle.state = .active
            circle.blendingMode = .behindWindow
            circle.wantsLayer = true
            circle.layer?.cornerRadius = circleSize / 2
            circle.layer?.masksToBounds = true
            circle.alphaValue = 0.6

            let iconView = NSImageView(frame: NSRect(x: (circleSize - 16) / 2, y: (circleSize - 16) / 2, width: 16, height: 16))
            iconView.imageScaling = .scaleProportionallyUpOrDown

            if i == 0 {
                if recording {
                    iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
                    iconView.contentTintColor = .labelColor
                } else {
                    iconView.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
                    iconView.contentTintColor = .secondaryLabelColor
                }
            } else {
                iconView.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
                iconView.contentTintColor = .tertiaryLabelColor
            }

            circle.addSubview(iconView)
            container.addSubview(circle)
            queueCircles.append(circle)
            queueIcons.append(iconView)
        }

        if let screen = NSScreen.main {
            let x = (screen.frame.width - windowWidth) / 2
            let y = screen.frame.height * 0.6
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func clearQueueCircles() {
        queueCircles.forEach { $0.removeFromSuperview() }
        queueCircles.removeAll()
        queueIcons.removeAll()
    }

    func dequeueOne() {
        if queueCount > 0 {
            queueCount -= 1
        }
        hideLiveText()
    }

    func updateLiveText(_ text: String) {
        guard !text.isEmpty else { return }

        let bubbleWidth: CGFloat = 320
        let textPadding: CGFloat = 12
        let textWidth = bubbleWidth - textPadding * 2

        if liveTextBubble == nil {
            let bubble = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: bubbleWidth, height: 50))
            bubble.material = .hudWindow
            bubble.state = .active
            bubble.blendingMode = .behindWindow
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 12
            bubble.layer?.masksToBounds = true
            bubble.alphaValue = 0.6

            let textLabel = NSTextField(wrappingLabelWithString: "")
            textLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            textLabel.textColor = .labelColor
            textLabel.backgroundColor = .clear
            textLabel.isBezeled = false
            textLabel.isEditable = false
            textLabel.maximumNumberOfLines = 0
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.preferredMaxLayoutWidth = textWidth
            textLabel.cell?.wraps = true

            bubble.addSubview(textLabel)
            container.addSubview(bubble)

            liveTextBubble = bubble
            liveTextLabel = textLabel
        }

        liveTextLabel?.stringValue = text
        liveTextLabel?.preferredMaxLayoutWidth = textWidth

        let textSize = liveTextLabel?.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)) ?? NSSize(width: textWidth, height: 20)
        let bubbleHeight = max(50, textSize.height + textPadding * 2)

        liveTextLabel?.frame = NSRect(x: textPadding, y: textPadding, width: textWidth, height: textSize.height)
        liveTextBubble?.frame.size.height = bubbleHeight

        let totalWidth = max(bubbleWidth, CGFloat(queueCount) * circleSize + CGFloat(queueCount - 1) * circleGap)
        let totalHeight = circleSize + 8 + bubbleHeight
        window.setContentSize(NSSize(width: totalWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)

        let circleY = bubbleHeight + 8
        for (i, circle) in queueCircles.enumerated() {
            let x = CGFloat(queueCount - 1 - i) * (circleSize + circleGap) + (totalWidth - CGFloat(queueCount) * circleSize - CGFloat(queueCount - 1) * circleGap) / 2
            circle.frame.origin = NSPoint(x: x, y: circleY)
        }

        liveTextBubble?.frame.origin = NSPoint(x: (totalWidth - bubbleWidth) / 2, y: 0)

        if let screen = NSScreen.main {
            let x = (screen.frame.width - totalWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    func hideLiveText() {
        liveTextBubble?.removeFromSuperview()
        liveTextBubble = nil
        liveTextLabel = nil
    }

    func resetToIdle() {
        stopAnimation()
        queueCount = 0
        clearQueueCircles()
        hideLiveText()
        glassButton.isHidden = false
        hide()
    }

    private func resizeWindowIconOnly() {
        let buttonWidth = padding + iconSize + padding
        let totalHeight = buttonHeight
        window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
        glassButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - buttonWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    private func resizeWindow(showStats: Bool) {
        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
        let totalHeight = showStats ? buttonHeight + dividerGap + cardHeight : buttonHeight
        window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
        container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
        glassButton.frame = NSRect(x: 0, y: showStats ? cardHeight + dividerGap : 0, width: buttonWidth, height: buttonHeight)
        label.frame.origin = NSPoint(x: padding + iconSize + spacing, y: (buttonHeight - label.frame.height) / 2)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        statsCard.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
        statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - buttonWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    @objc private func recordClicked() {
        hide()
        onRecord()
    }

    func toggle() {
        window.isVisible ? hide() : showIdle()
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let x = (screen.frame.width - window.frame.width) / 2
        let y = screen.frame.height * 0.6
        window.setFrameOrigin(NSPoint(x: x, y: y))

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if isExpanded {
            isExpanded = false
            clearTranscriptionItems()
            statsNumberLabel.isHidden = false
            statsDescLabel.isHidden = false
            statsClickButton.isHidden = false

            let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
            let totalHeight = buttonHeight + dividerGap + cardHeight
            window.setContentSize(NSSize(width: buttonWidth, height: totalHeight))
            container.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: totalHeight)
            glassButton.frame = NSRect(x: 0, y: cardHeight + dividerGap, width: buttonWidth, height: buttonHeight)
            statsCard.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
            statsNumberLabel.frame = NSRect(x: 0, y: cardHeight - 50, width: buttonWidth, height: 40)
            statsDescLabel.frame = NSRect(x: 0, y: 14, width: buttonWidth, height: 16)
            statsClickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: cardHeight)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            window.animator().alphaValue = 0
        }) { [weak self] in
            Task { @MainActor [weak self] in
                self?.window.orderOut(nil)
            }
        }
    }
}
