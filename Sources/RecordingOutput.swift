import Foundation
import AVFoundation

func eprint(_ message: String) {
    fputs(message + "\n", stderr)
}

/// Writes mixed audio to the .m4a file and, optionally, raw PCM to stdout. Encoding happens off the capture threads.
final class RecordingOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "audio-capture.writer")
    private var file: AVAudioFile?
    private let pipe: PipeWriter?
    private var reportedFileError = false

    init(fileURL: URL, pipeSampleRate: Double?) throws {
        file = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioMixer.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        pipe = try pipeSampleRate.map { try PipeWriter(sampleRate: $0) }
    }

    func write(_ samples: [Float]) {
        queue.async { [self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            do {
                try file?.write(from: buffer)
            } catch where !reportedFileError {
                reportedFileError = true
                eprint("Failed to write audio file: \(error.localizedDescription)")
            } catch {}
            pipe?.write(buffer)
        }
    }

    func close() {
        queue.sync {
            if #available(macOS 15.0, *) {
                file?.close()
            }
            file = nil
            pipe?.finish()
        }
        pipe?.waitUntilDrained()
    }
}

/// Streams s16le mono PCM to stdout on its own queue so a slow reader can never stall recording.
final class PipeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "audio-capture.pipe")
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let maxPendingBytes: Int
    private let lock = NSLock()
    private var pendingBytes = 0
    private var broken = false
    private var dropping = false

    init(sampleRate: Double) throws {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: AudioMixer.format, to: outputFormat) else {
            throw NSError(domain: "AudioCapture", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unsupported pipe sample rate: \(sampleRate)"])
        }
        self.converter = converter
        maxPendingBytes = Int(sampleRate) * 2 * 30
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        convert(buffer, endOfStream: false)
    }

    func finish() {
        convert(nil, endOfStream: true)
    }

    func waitUntilDrained() {
        queue.sync {}
        Darwin.close(STDOUT_FILENO)
    }

    private func convert(_ input: AVAudioPCMBuffer?, endOfStream: Bool) {
        let inputFrames = Double(input?.frameLength ?? 0)
        let capacity = AVAudioFrameCount(inputFrames * outputFormat.sampleRate / AudioMixer.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if let input, !fed {
                fed = true
                status.pointee = .haveData
                return input
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        guard error == nil, output.frameLength > 0 else { return }
        enqueue(Data(bytes: output.int16ChannelData![0], count: Int(output.frameLength) * 2))
    }

    private func enqueue(_ data: Data) {
        lock.lock()
        if broken {
            lock.unlock()
            return
        }
        if pendingBytes + data.count > maxPendingBytes {
            if !dropping {
                dropping = true
                eprint("Warning: stdout reader is falling behind, dropping piped audio (the file is unaffected).")
            }
            lock.unlock()
            return
        }
        dropping = false
        pendingBytes += data.count
        lock.unlock()

        queue.async { [self] in
            let ok = isBroken ? false : data.withUnsafeBytes { writeAll($0) }
            lock.lock()
            pendingBytes -= data.count
            if !ok && !broken {
                broken = true
                eprint("stdout closed, continuing to record to file only.")
            }
            lock.unlock()
        }
    }

    private var isBroken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return broken
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
