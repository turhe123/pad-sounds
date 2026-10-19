import AVFoundation
import AudioToolbox

/// Owns the AVAudioEngine graph: one AVAudioPlayerNode per pad feeding the main mixer.
/// Short clips are decoded into memory; large files are streamed with `scheduleFile`.
final class PadAudioEngine {
    /// Per-pad playback state. `generation` invalidates completion callbacks from earlier plays.
    private final class Slot {
        let node = AVAudioPlayerNode()
        var file: AVAudioFile?
        var buffer: AVAudioPCMBuffer?
        var generation = 0
        var isPlaying = false
        var loops = false
        var fadeTimer: Timer?
    }

    /// Files whose decoded size exceeds this are streamed instead of loaded wholly.
    private let maxBufferBytes: Int64 = 24 * 1024 * 1024
    private let engine = AVAudioEngine()
    private var slots: [UUID: Slot] = [:]

    /// Called on the main queue when a pad finishes playing on its own.
    var onFinished: ((UUID) -> Void)?
    /// Called on the main queue when the engine was reset by the system (e.g. device change).
    var onReset: (() -> Void)?

    init() {
        _ = engine.mainMixerNode
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    var masterVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    @discardableResult
    func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        engine.prepare()
        do { try engine.start(); return true } catch { return false }
    }

    /// Opens `url`, wires the pad's node with the file's format (the mixer resamples), and buffers short clips.
    func load(_ id: UUID, url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        stop(id)
        let slot = slots[id] ?? {
            let s = Slot()
            engine.attach(s.node)
            slots[id] = s
            return s
        }()
        let format = file.processingFormat
        engine.disconnectNodeOutput(slot.node)
        engine.connect(slot.node, to: engine.mainMixerNode, format: format)
        slot.buffer = nil
        let bytes = file.length * Int64(format.channelCount) * 4
        if bytes < maxBufferBytes, file.length > 0,
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) {
            try file.read(into: buffer)
            slot.buffer = buffer
        }
        slot.file = file
    }

    func unload(_ id: UUID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        slot.fadeTimer?.invalidate()
        slot.node.stop()
        engine.detach(slot.node)
    }

    func isLoaded(_ id: UUID) -> Bool { slots[id]?.file != nil }
    func isPlaying(_ id: UUID) -> Bool { slots[id]?.isPlaying ?? false }

    /// Starts (or restarts) a pad from the beginning. Returns false if the engine could not run.
    func play(_ id: UUID, volume: Float, loops: Bool) -> Bool {
        guard let slot = slots[id], let file = slot.file, startIfNeeded() else { return false }
        slot.fadeTimer?.invalidate()
        slot.generation += 1
        slot.node.stop()
        slot.node.volume = volume
        slot.loops = loops
        let gen = slot.generation
        if let buffer = slot.buffer {
            slot.node.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [],
                                     completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { self?.finished(id, generation: gen) }
            }
        } else {
            file.framePosition = 0
            scheduleStream(slot, file: file, id: id, generation: gen)
            // Queue a second pass ahead of time so looping streams have no gap.
            if loops { scheduleStream(slot, file: file, id: id, generation: gen) }
        }
        slot.node.play()
        slot.isPlaying = true
        return true
    }

    private func scheduleStream(_ slot: Slot, file: AVAudioFile, id: UUID, generation gen: Int) {
        slot.node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, slot.generation == gen, slot.isPlaying else { return }
                if slot.loops {
                    self.scheduleStream(slot, file: file, id: id, generation: gen)
                } else {
                    self.finished(id, generation: gen)
                }
            }
        }
    }

    private func finished(_ id: UUID, generation: Int) {
        guard let slot = slots[id], slot.generation == generation, slot.isPlaying else { return }
        slot.isPlaying = false
        onFinished?(id)
    }

    func setVolume(_ id: UUID, _ volume: Float) {
        guard let slot = slots[id], slot.fadeTimer == nil else { return }
        slot.node.volume = volume
    }

    /// Stops immediately.
    func stop(_ id: UUID) {
        guard let slot = slots[id] else { return }
        slot.fadeTimer?.invalidate()
        slot.fadeTimer = nil
        slot.generation += 1
        slot.isPlaying = false
        slot.node.stop()
    }

    /// Ramps the node volume to zero over `duration` seconds, then stops. `completion` runs once stopped.
    func fadeOut(_ id: UUID, duration: Double, completion: @escaping () -> Void) {
        guard let slot = slots[id], slot.isPlaying else { completion(); return }
        guard duration > 0.01 else { stop(id); completion(); return }
        slot.fadeTimer?.invalidate()
        let start = slot.node.volume
        let began = Date()
        let gen = slot.generation
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            let progress = Date().timeIntervalSince(began) / duration
            guard slot.generation == gen, progress < 1 else {
                t.invalidate()
                if slot.generation == gen { self?.stop(id); completion() }
                return
            }
            slot.node.volume = start * Float(1 - progress)
        }
        RunLoop.main.add(timer, forMode: .common)
        slot.fadeTimer = timer
    }

    /// Playback position in 0…1 within the current pass of the clip.
    func progress(_ id: UUID) -> Double {
        guard let slot = slots[id], slot.isPlaying, let file = slot.file,
              let nodeTime = slot.node.lastRenderTime,
              let playerTime = slot.node.playerTime(forNodeTime: nodeTime) else { return 0 }
        let length = Int64(slot.buffer?.frameLength ?? AVAudioFrameCount(clamping: file.length))
        guard length > 0, playerTime.sampleTime >= 0 else { return 0 }
        return Double(playerTime.sampleTime % length) / Double(length)
    }

    /// Routes the engine's output unit to a specific CoreAudio device.
    func setOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        slots.keys.forEach(stop)
        engine.stop()
        guard let unit = engine.outputNode.audioUnit else { return false }
        var device = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        startIfNeeded()
        return status == noErr
    }

    private func handleConfigurationChange() {
        for slot in slots.values {
            slot.fadeTimer?.invalidate()
            slot.fadeTimer = nil
            slot.generation += 1
            slot.isPlaying = false
        }
        startIfNeeded()
        onReset?()
    }
}
