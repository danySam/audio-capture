import Foundation
import AVFoundation

// MARK: - Merge helper

func mergeAudio(system: URL, mic: URL, to output: URL) async throws {
    let systemAsset = AVURLAsset(url: system)
    let micAsset = AVURLAsset(url: mic)

    let composition = AVMutableComposition()

    if let track = try await systemAsset.loadTracks(withMediaType: .audio).first,
       let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        let duration = try await systemAsset.load(.duration)
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
    }

    if let track = try await micAsset.loadTracks(withMediaType: .audio).first,
       let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        let duration = try await micAsset.load(.duration)
        try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
    }

    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
        throw NSError(domain: "AudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
    }
    try await session.export(to: output, as: .m4a)
}

// MARK: - Parse arguments

var outputDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Recordings")

var label: String? = nil

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--output", "-o":
        guard let path = args.next() else {
            fputs("Error: --output requires a path\n", stderr)
            exit(1)
        }
        outputDir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    case "--name", "-n":
        guard let name = args.next() else {
            fputs("Error: --name requires a label\n", stderr)
            exit(1)
        }
        label = name
    case "--help", "-h":
        print("""
        audio-capture — Record system audio and microphone

        Usage: audio-capture [--name <label>] [--output <directory>]

        Options:
          -n, --name <label>  Label for the recording (e.g. "standup", "1on1-with-alex")
          -o, --output <dir>  Output directory (default: ~/Recordings)
          -h, --help          Show this help

        Saves a single merged .m4a file with both system audio and mic:
          <timestamp>[_label].m4a

        Press Ctrl+C to stop recording.
        First run will prompt for Screen Recording and Microphone permissions.
        """)
        exit(0)
    default:
        fputs("Unknown option: \(arg). Use --help for usage.\n", stderr)
        exit(1)
    }
}

// MARK: - Setup

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
let timestamp = formatter.string(from: Date())
let sanitizedLabel = label.map { $0.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression) }
let prefix = [timestamp, sanitizedLabel].compactMap({ $0 }).joined(separator: "_")

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("audio-capture-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
let systemTempURL = tempDir.appendingPathComponent("system.m4a")
let micTempURL = tempDir.appendingPathComponent("mic.m4a")

// MARK: - Signal handling (Ctrl+C / kill)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let stopSignal = AsyncStream<Void> { continuation in
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            continuation.yield()
            continuation.finish()
        }
        source.resume()
        return source
    }
    continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
}

// MARK: - Start system audio

print("Starting recording...")

let systemRecorder = SystemAudioRecorder()
do {
    try await systemRecorder.start(to: systemTempURL)
} catch {
    fputs("Failed to start system audio: \(error.localizedDescription)\n", stderr)
    fputs("Grant Screen Recording permission in System Settings → Privacy & Security.\n", stderr)
    try? FileManager.default.removeItem(at: tempDir)
    exit(1)
}

// MARK: - Start microphone

let micRecorder: AVAudioRecorder
do {
    micRecorder = try AVAudioRecorder(url: micTempURL, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64000,
    ])
} catch {
    fputs("Failed to set up microphone: \(error.localizedDescription)\n", stderr)
    fputs("Grant Microphone permission in System Settings → Privacy & Security.\n", stderr)
    try? await systemRecorder.stop()
    try? FileManager.default.removeItem(at: tempDir)
    exit(1)
}

guard micRecorder.record() else {
    fputs("Failed to start microphone recording.\n", stderr)
    try? await systemRecorder.stop()
    try? FileManager.default.removeItem(at: tempDir)
    exit(1)
}

// MARK: - Recording

let startTime = Date()
print("Recording started at \(DateFormatter.localizedString(from: startTime, dateStyle: .none, timeStyle: .short))")
print("Press Ctrl+C to stop.")

for await _ in stopSignal { break }

// MARK: - Stop and merge

let elapsed = Int(Date().timeIntervalSince(startTime))

print("\nStopping...")
micRecorder.stop()
try await systemRecorder.stop()

let h = elapsed / 3600
let m = (elapsed % 3600) / 60
let s = elapsed % 60
let duration = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)

let outputURL = outputDir.appendingPathComponent("\(prefix).m4a")

print("Merging audio...")
do {
    try await mergeAudio(system: systemTempURL, mic: micTempURL, to: outputURL)
    try? FileManager.default.removeItem(at: tempDir)
    print("Saved (\(duration))")
    print("  \(outputURL.path)")
} catch {
    let systemFallback = outputDir.appendingPathComponent("\(prefix)_system.m4a")
    let micFallback = outputDir.appendingPathComponent("\(prefix)_mic.m4a")
    try? FileManager.default.moveItem(at: systemTempURL, to: systemFallback)
    try? FileManager.default.moveItem(at: micTempURL, to: micFallback)
    try? FileManager.default.removeItem(at: tempDir)
    fputs("Merge failed: \(error.localizedDescription)\n", stderr)
    print("Saved individual files instead (\(duration)):")
    print("  \(systemFallback.path)")
    print("  \(micFallback.path)")
}
