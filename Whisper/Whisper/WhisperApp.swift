import SwiftUI
import AppKit
import AVFoundation
import WhisperKit
import os.log
import Quartz

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

private let appLogger = Logger(subsystem: "soli.whisper.Whisper", category: "app")
let minRecordSeconds = 0.3
let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dictate_transcripts", isDirectory: true)
let focusDebugLog = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dictate_transcripts/focus_debug.log")

func logFocusDebug(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: focusDebugLog) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(to: focusDebugLog, atomically: true, encoding: .utf8)
    }
}

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
            launcherPanel?.toggle()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        selectedLanguage = sender.representedObject as? String
    }

    private func updateLanguageMenu() {
        languageMenu?.items.forEach { item in
            let code = item.representedObject as? String
            item.state = (code == selectedLanguage) ? .on : .off
        }
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
            launcherPanel?.hideLoading()
        } catch {
            appLogger.error("Failed to load Whisper model: \(error.localizedDescription)")
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
        updateIcon(.recording)
        statusItem.menu?.item(at: 0)?.title = "Stop Recording"
        screenGlow?.show(mode: .recording)
        launcherPanel?.showRecording()
        appLogger.info("Recording started")
    }

    private var savedWindow: AXUIElement?
    private var savedAppPid: pid_t = 0
    private var savedWindowId: CGWindowID = 0
    private var savedWindowTitle: String = ""

    private func logFocusInfo() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        savedAppPid = frontApp.processIdentifier

        logFocusDebug("=== Recording Started ===")
        logFocusDebug("App: \(frontApp.localizedName ?? "nil") | bundle: \(frontApp.bundleIdentifier ?? "nil") | pid: \(savedAppPid)")

        let appRef = AXUIElementCreateApplication(savedAppPid)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        if result == .success, let window = focusedWindowRef {
            savedWindow = (window as! AXUIElement)
            _AXUIElementGetWindow(savedWindow!, &savedWindowId)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(savedWindow!, kAXTitleAttribute as CFString, &titleRef)
            savedWindowTitle = titleRef as? String ?? ""
            logFocusDebug("Focused window: id=\(savedWindowId) title=\(savedWindowTitle)")
        } else {
            logFocusDebug("Could not get focused window: \(result.rawValue)")
            savedWindow = nil
            savedWindowId = 0
            savedWindowTitle = ""
        }
    }

    private func windowChanged() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return true }

        if frontApp.processIdentifier != savedAppPid {
            logFocusDebug("Different app - will restore")
            return false
        }

        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)

        guard result == .success, let window = focusedWindowRef else {
            logFocusDebug("Could not get current focused window")
            return false
        }

        var currentWindowId: CGWindowID = 0
        _AXUIElementGetWindow(window as! AXUIElement, &currentWindowId)

        let changed = currentWindowId != savedWindowId
        logFocusDebug("Window check: saved=\(savedWindowId) current=\(currentWindowId) changed=\(changed)")
        return changed
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    private func restoreSavedWindow() {
        logFocusDebug("=== Restoring Window ===")

        guard let window = savedWindow else {
            logFocusDebug("No saved window")
            return
        }

        var windowId: CGWindowID = 0
        _AXUIElementGetWindow(window, &windowId)
        logFocusDebug("Restoring window id: \(windowId) pid: \(savedAppPid) title: \(savedWindowTitle)")

        guard let app = NSRunningApplication(processIdentifier: savedAppPid) else {
            logFocusDebug("Could not find app")
            return
        }

        let activated = app.activate(options: [.activateIgnoringOtherApps])
        logFocusDebug("App activate result: \(activated)")

        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        logFocusDebug("Raise result: \(raiseResult.rawValue)")
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func stopRecording() {
        let samples = recorder.stop()
        isRecording = false
        updateIcon(.ready)
        statusItem.menu?.item(at: 0)?.title = "Start Recording"
        appLogger.info("Recording stopped, samples: \(samples.count)")

        guard !samples.isEmpty else {
            appLogger.info("No audio captured")
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            return
        }

        let duration = Double(samples.count) / recorder.sampleRate
        appLogger.info("Audio duration: \(String(format: "%.2f", duration))s")

        if duration < minRecordSeconds {
            appLogger.info("Audio too short")
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            showNotification(title: "Whisper", message: "Recording too short. Hold Right Option longer.")
            return
        }

        isTranscribing = true
        updateIcon(.transcribing)
        screenGlow?.show(mode: .transcribing)
        launcherPanel?.showTranscribing()

        Task {
            await transcribe(samples: samples)
        }
    }

    private func transcribe(samples: [Float]) async {
        guard let whisperKit else {
            appLogger.error("WhisperKit not initialized")
            screenGlow?.hide()
            launcherPanel?.resetToIdle()
            updateIcon(.ready)
            isTranscribing = false
            return
        }

        do {
            let resampled = resampleTo16kHz(samples: samples, fromRate: recorder.sampleRate)
            let options = DecodingOptions(language: selectedLanguage)
            let results = try await whisperKit.transcribe(audioArray: resampled, decodeOptions: options)
            let text = results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)

            appLogger.info("Transcription: \(text.prefix(100))...")

            if text.isEmpty {
                showNotification(title: "Whisper", message: "No speech detected. Try again.")
            } else {
                saveTranscript(text)
                if windowChanged() {
                    copyToClipboard(text)
                    showNotification(title: "Whisper", message: "Window changed - copied to clipboard")
                    logFocusDebug("Window changed within same app, skipping paste")
                } else {
                    restoreSavedWindow()
                    copyAndPaste(text)
                }
            }
        } catch {
            appLogger.error("Transcription failed: \(error.localizedDescription)")
            showNotification(title: "Whisper", message: "Transcription failed: \(error.localizedDescription)")
        }

        screenGlow?.hide()
        launcherPanel?.resetToIdle()
        updateIcon(.ready)
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
        appLogger.info("Paste sent")
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
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
            self?.iconAnimationFrame += 1
            self?.updateLoadingFrame()
        }
    }

    private func updateLoadingFrame() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let angle = CGFloat(iconAnimationFrame * 30)
        let size = NSSize(width: 18, height: 18)
        let rotated = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current?.cgContext
            context?.translateBy(x: size.width / 2, y: size.height / 2)
            context?.rotate(by: angle * .pi / 180)
            context?.translateBy(x: -size.width / 2, y: -size.height / 2)
            baseImage.draw(in: rect)
            return true
        }
        rotated.isTemplate = true
        statusItem.button?.image = rotated
    }

    private func animateRecording() {
        updateRecordingFrame()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.iconAnimationFrame += 1
            self?.updateRecordingFrame()
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
            self?.iconAnimationFrame += 1
            self?.updateTranscribingFrame()
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
            self?.window?.orderOut(nil)
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
                guard let self, let layer = self.layer else { return }
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 0.7
                animation.toValue = 0.35
                animation.duration = 1.2
                animation.autoreverses = true
                layer.add(animation, forKey: "pulse")
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
    private var glassButton: NSVisualEffectView!
    private var micIcon: NSImageView!
    private var label: NSTextField!
    private var clickButton: NSButton!
    private let buttonHeight: CGFloat = 48
    private let padding: CGFloat = 16
    private let iconSize: CGFloat = 20
    private let spacing: CGFloat = 10
    private var animationTimer: Timer?
    private var rotationAngle: CGFloat = 0
    private var transcribeFrame: Int = 0

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

        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false

        glassButton = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight))
        glassButton.material = .hudWindow
        glassButton.state = .active
        glassButton.blendingMode = .behindWindow
        glassButton.wantsLayer = true
        glassButton.layer?.cornerRadius = cornerRadius
        glassButton.layer?.masksToBounds = true

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
        window.contentView = glassButton
    }

    func showLoading() {
        stopAnimation()
        label.isHidden = false
        label.stringValue = "loading model"
        label.sizeToFit()
        resizeWindow()
        updateGearIcon()
        show()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.rotationAngle += 6
            self.updateGearIcon()
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
        resizeWindow()
        show()
    }

    private func updateGearIcon() {
        guard let baseImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else { return }
        let size = NSSize(width: iconSize, height: iconSize)
        let rotated = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            NSGraphicsContext.current?.cgContext.rotate(by: self.rotationAngle * .pi / 180)
            NSGraphicsContext.current?.cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            baseImage.draw(in: rect)
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
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        micIcon.contentTintColor = .labelColor
        label.isHidden = true
        resizeWindowIconOnly()
        show()
    }

    func showTranscribing() {
        stopAnimation()
        label.isHidden = true
        resizeWindowIconOnly()
        updateTranscribeIcon()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.transcribeFrame += 1
            self.updateTranscribeIcon()
        }
    }

    private func updateTranscribeIcon() {
        let icons = ["ellipsis", "ellipsis", "sparkle", "ellipsis"]
        let icon = icons[transcribeFrame % icons.count]
        micIcon.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        micIcon.contentTintColor = .secondaryLabelColor
    }

    func resetToIdle() {
        stopAnimation()
        hide()
    }

    private func resizeWindowIconOnly() {
        let buttonWidth = padding + iconSize + padding
        window.setContentSize(NSSize(width: buttonWidth, height: buttonHeight))
        glassButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - buttonWidth) / 2
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.origin.y))
        }
    }

    private func resizeWindow() {
        let buttonWidth = padding + iconSize + spacing + label.frame.width + padding
        window.setContentSize(NSSize(width: buttonWidth, height: buttonHeight))
        glassButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
        label.frame.origin = NSPoint(x: padding + iconSize + spacing, y: (buttonHeight - label.frame.height) / 2)
        clickButton.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: buttonHeight)
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

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            window.animator().alphaValue = 0
        }) { [weak self] in
            self?.window.orderOut(nil)
        }
    }
}
