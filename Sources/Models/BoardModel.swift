import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

/// Central app state: the pad board, its persistence in Application Support, playback through
/// `PadAudioEngine`, output-device selection and keyboard triggering (local and optional global).
final class BoardModel: ObservableObject {
    @Published var pads: [Pad] { didSet { if pads != oldValue { save() } } }
    @Published private(set) var playing: Set<UUID> = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var broken: Set<UUID> = []
    @Published private(set) var devices: [AudioDevice] = []
    @Published var toast: String?

    @Published var masterVolume: Double { didSet { defaults.set(masterVolume, forKey: "masterVolume"); audio.masterVolume = Float(masterVolume) } }
    @Published var fadeOut: Double { didSet { defaults.set(fadeOut, forKey: "fadeOut") } }
    @Published var keysActive: Bool { didSet { defaults.set(keysActive, forKey: "keysActive") } }
    @Published var globalKeys: Bool { didSet { defaults.set(globalKeys, forKey: "globalKeys"); updateGlobalMonitor() } }
    /// Empty string means "System Default".
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID"); applyOutputDevice() } }

    private let defaults = UserDefaults.standard
    private let audio = PadAudioEngine()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var progressTimer: Timer?
    private var toastWork: DispatchWorkItem?

    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("PadSounds", isDirectory: true)
    }()
    private var soundsDir: URL { supportDir.appendingPathComponent("Sounds", isDirectory: true) }
    private var boardURL: URL { supportDir.appendingPathComponent("board.json") }

    init() {
        defaults.register(defaults: ["masterVolume": 0.9, "fadeOut": 0.5, "keysActive": true])
        masterVolume = defaults.double(forKey: "masterVolume")
        fadeOut = defaults.double(forKey: "fadeOut")
        keysActive = defaults.bool(forKey: "keysActive")
        globalKeys = defaults.bool(forKey: "globalKeys")
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        pads = Pad.defaultBoard()
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: boardURL) {
            if let saved = try? JSONDecoder().decode([Pad].self, from: data), !saved.isEmpty {
                pads = Array((saved + Pad.defaultBoard()).prefix(16))
            } else {
                showToast("The saved board could not be read, so a new one was started.")
            }
        }

        audio.masterVolume = Float(masterVolume)
        audio.onFinished = { [weak self] id in self?.playing.remove(id) }
        audio.onReset = { [weak self] in self?.playing.removeAll() }
        audio.startIfNeeded()
        pads.forEach(loadAudio)
        if !broken.isEmpty { showToast("\(broken.count) pad(s) have a missing or unreadable file.") }

        refreshDevices(notify: true)
        applyOutputDevice()
        AudioDevices.observeChanges { [weak self] in self?.refreshDevices(notify: true) }

        installLocalMonitor()
        updateGlobalMonitor()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.updateGlobalMonitor() }
    }

    // MARK: Persistence & files

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(pads).write(to: boardURL, options: .atomic)
        } catch {
            showToast("Couldn't save the board: \(error.localizedDescription)")
        }
    }

    private func loadAudio(_ pad: Pad) {
        guard let name = pad.fileName else { broken.remove(pad.id); return }
        do {
            try audio.load(pad.id, url: soundsDir.appendingPathComponent(name))
            broken.remove(pad.id)
        } catch {
            broken.insert(pad.id)
        }
    }

    /// Copies an audio file into Application Support and assigns it to the pad.
    func assignFile(_ source: URL, to id: UUID) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard UTType(filenameExtension: source.pathExtension)?.conforms(to: .audio) == true else {
            showToast("“\(source.lastPathComponent)” is not an audio file.")
            return
        }
        let dest = soundsDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            try audio.load(id, url: dest)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            showToast("Couldn't import “\(source.lastPathComponent)”: \(error.localizedDescription)")
            return
        }
        playing.remove(id)
        removeStoredFile(pads[index].fileName)
        pads[index].fileName = dest.lastPathComponent
        if pads[index].label.hasPrefix("Pad ") || pads[index].label.isEmpty {
            pads[index].label = source.deletingPathExtension().lastPathComponent
        }
        broken.remove(id)
    }

    /// Clears the pad's audio and resets it to an empty pad, keeping its key and colour.
    func clearPad(_ id: UUID) {
        guard let index = pads.firstIndex(where: { $0.id == id }) else { return }
        audio.unload(id)
        playing.remove(id)
        broken.remove(id)
        removeStoredFile(pads[index].fileName)
        pads[index].fileName = nil
        pads[index].label = "Pad \(index + 1)"
    }

    private func removeStoredFile(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: soundsDir.appendingPathComponent(name))
    }

    /// Assigns a single-character key, rejecting duplicates. Returns false if rejected.
    @discardableResult
    func setKey(_ key: String?, for id: UUID) -> Bool {
        let normalized = key.flatMap { $0.isEmpty ? nil : String($0.suffix(1)).lowercased() }
        if let normalized, let other = pads.first(where: { $0.key == normalized && $0.id != id }) {
            showToast("Key “\(normalized.uppercased())” is already used by “\(other.label)”.")
            return false
        }
        if let index = pads.firstIndex(where: { $0.id == id }) { pads[index].key = normalized }
        return true
    }

    func volumeChanged(_ pad: Pad) { audio.setVolume(pad.id, Float(pad.volume)) }

    // MARK: Playback

    func press(_ pad: Pad) {
        guard pad.fileName != nil else { return }
        guard !broken.contains(pad.id), audio.isLoaded(pad.id) else {
            showToast("The file for “\(pad.label)” is missing or unreadable. Use Replace File.")
            return
        }
        if pad.mode == .toggle, playing.contains(pad.id) {
            stop(pad.id)
            return
        }
        if audio.play(pad.id, volume: Float(pad.volume), loops: pad.loops) {
            playing.insert(pad.id)
            startProgressTimer()
        } else {
            showToast("The audio output could not be started.")
        }
    }

    func release(_ pad: Pad) {
        if pad.mode == .hold { stop(pad.id) }
    }

    func stop(_ id: UUID) {
        audio.fadeOut(id, duration: fadeOut) { [weak self] in self?.playing.remove(id) }
    }

    func stopAll() { playing.forEach(stop) }

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.progress = Dictionary(uniqueKeysWithValues: self.playing.map { ($0, self.audio.progress($0)) })
            if self.playing.isEmpty { t.invalidate(); self.progressTimer = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    // MARK: Output devices

    private func refreshDevices(notify: Bool) {
        devices = AudioDevices.outputDevices()
        if !outputUID.isEmpty, !devices.contains(where: { $0.uid == outputUID }) {
            outputUID = ""
            if notify { showToast("The selected output device disappeared — using the system default.") }
        }
    }

    private func applyOutputDevice() {
        let selected = devices.first(where: { $0.uid == outputUID })
        if !outputUID.isEmpty, selected == nil {
            outputUID = ""
            showToast("The saved output device isn't available — using the system default.")
            return
        }
        playing.removeAll()
        if !audio.setOutputDevice(selected?.id ?? AudioDevices.defaultOutputID()) {
            showToast("Couldn't switch the output device.")
        }
    }

    // MARK: Keyboard

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event, global: false) ? nil : event
        }
    }

    /// Returns true when the event triggered something and should be swallowed.
    private func handleKey(_ event: NSEvent, global: Bool) -> Bool {
        if !global {
            // Never steal keystrokes from text fields such as the label editor.
            if event.window?.firstResponder is NSText { return false }
            if event.modifierFlags.contains(.command) { return false }
            if event.keyCode == 53 {
                if event.type == .keyDown { stopAll() }
                return true
            }
        }
        guard keysActive || global,
              let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty,
              let pad = pads.first(where: { $0.key == chars }) else { return false }
        if event.type == .keyDown {
            if !event.isARepeat { press(pad) }
        } else {
            release(pad)
        }
        return true
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (call only after explaining why).
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Global triggers use ⌃⌥ + the pad's key while another app is frontmost.
    private func updateGlobalMonitor() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        guard globalKeys, AXIsProcessTrusted() else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.modifierFlags.contains([.control, .option]) else { return }
            _ = self?.handleKey(event, global: true)
        }
    }

    // MARK: Toast

    func showToast(_ message: String) {
        toastWork?.cancel()
        toast = message
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
}
