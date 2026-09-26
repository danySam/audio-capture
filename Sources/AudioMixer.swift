import Foundation
import AVFoundation
import CoreMedia

enum AudioSource: Int {
    case system = 0
    case mic = 1
}

/// Mixes the sources onto a shared host-time timeline and emits contiguous 48kHz mono chunks.
final class AudioMixer: @unchecked Sendable {
    static let sampleRate = 48000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private let startTime = CMClockGetTime(CMClockGetHostTimeClock())
    // How long to wait for a lagging (or silent) source before emitting without it.
    private let maxLag = Int64(0.5 * sampleRate)
    // Buffers are placed back-to-back unless their timestamp drifts further than this, which avoids clicks from jitter.
    private let resyncThreshold = Int64(0.03 * sampleRate)
    private var timeline: [Float] = []
    private var baseFrame: Int64 = 0
    private var cursors: [Int64?] = [nil, nil]
    private var clockOffsets: [Int64?] = [nil, nil]
    private let emit: ([Float]) -> Void

    init(emit: @escaping ([Float]) -> Void) {
        self.emit = emit
    }

    func append(_ samples: [Float], from source: AudioSource, at hostTime: CMTime) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        let i = source.rawValue
        let raw = frame(at: hostTime)
        if clockOffsets[i] == nil {
            // Fall back to arrival time if a source's timestamps aren't on the host clock.
            let now = frame(at: CMClockGetTime(CMClockGetHostTimeClock()))
            clockOffsets[i] = abs(raw - now) > Int64(2 * Self.sampleRate) ? now - raw : 0
        }
        let placed = raw + clockOffsets[i]!
        var start = placed
        if let cursor = cursors[i], abs(placed - cursor) < resyncThreshold {
            start = cursor
        }
        cursors[i] = start + Int64(samples.count)

        let skip = Int(max(0, baseFrame - start))
        guard skip < samples.count else { return }
        let index = Int(max(start, baseFrame) - baseFrame)
        let count = samples.count - skip
        if timeline.count < index + count {
            timeline.append(contentsOf: repeatElement(0, count: index + count - timeline.count))
        }
        for j in 0..<count {
            timeline[index + j] += samples[skip + j]
        }
        drain(final: false)
    }

    func finish() {
        lock.lock()
        drain(final: true)
        lock.unlock()
    }

    private func frame(at time: CMTime) -> Int64 {
        Int64((time - startTime).seconds * Self.sampleRate)
    }

    private func drain(final: Bool) {
        let end = baseFrame + Int64(timeline.count)
        var ready = end
        if !final {
            ready = cursors.map { $0 ?? baseFrame }.min()!
            ready = min(max(ready, end - maxLag), end)
        }
        let n = Int(ready - baseFrame)
        guard n > 0 else { return }
        let chunk = timeline[0..<n].map { min(max($0, -1), 1) }
        timeline.removeFirst(n)
        baseFrame = ready
        emit(chunk)
    }
}

/// Converts a source's sample buffers to the mixer format. Not thread-safe; use one per source queue.
final class SampleExtractor {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func samples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
        guard status == noErr else { return nil }

        if format == AudioMixer.format {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(frames)))
        }

        if sourceFormat != format {
            converter = AVAudioConverter(from: format, to: AudioMixer.format)
            converter?.downmix = true
            sourceFormat = format
        }
        guard let converter else { return nil }

        let capacity = AVAudioFrameCount(Double(frames) * AudioMixer.sampleRate / format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
