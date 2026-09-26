import Foundation
import AVFoundation

// MARK: - Helpers

func discoverInputDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    ).devices
}

func findDevice(matching name: String) -> AVCaptureDevice? {
    discoverInputDevices().first { $0.localizedName.localizedCaseInsensitiveContains(name) }
}

// MARK: - Parse arguments

var outputDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Recordings")
var label: String? = nil
var deviceQuery: String? = nil
var pipeRate = 16000.0

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--output", "-o":
        guard let path = args.next() else {
            eprint("Error: --output requires a path")
            exit(1)
        }
        outputDir = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    case "--name", "-n":
        guard let name = args.next() else {
            eprint("Error: --name requires a label")
            exit(1)
        }
        label = name
    case "--device", "-d":
        guard let name = args.next() else {
            eprint("Error: --device requires a device name")
            exit(1)
        }
        deviceQuery = name
    case "--pipe-rate", "-r":
        guard let value = args.next(), let rate = Double(value), rate >= 8000, rate <= 192000 else {
            eprint("Error: --pipe-rate requires a sample rate in Hz (e.g. 16000)")
            exit(1)
        }
        pipeRate = rate
    case "--list-devices", "-l":
        let devices = discoverInputDevices()
        let defaultDevice = AVCaptureDevice.default(for: .audio)
        if devices.isEmpty {
            print("No audio input devices found.")
        } else {
            for device in devices {
                let marker = device.uniqueID == defaultDevice?.uniqueID ? " (default)" : ""
                print("  \(device.localizedName)\(marker)")
            }
        }
        exit(0)
    case "--help", "-h":
        print("""
        audio-capture — Record system audio and microphone

        Usage: audio-capture [options] [| other-command]

        Options:
          -n, --name <label>    Label for the recording (e.g. "standup", "1on1-with-alex")
          -d, --device <name>   Microphone to use (substring match, see --list-devices)
          -l, --list-devices    List available microphones
          -o, --output <dir>    Output directory (default: ~/Recordings)
          -r, --pipe-rate <hz>  Sample rate of piped audio (default: 16000)
          -h, --help            Show this help

        Saves a single mixed .m4a file with both system audio and mic:
          <timestamp>[_label].m4a

        When stdout is piped, the mixed audio is also streamed live as raw PCM
        (signed 16-bit little-endian, mono, --pipe-rate Hz). Status goes to stderr.
          audio-capture -n standup | transcribe -o standup.txt

        Press Ctrl+C to stop recording.
        First run will prompt for Screen Recording and Microphone permissions.
        """)
        exit(0)
    default:
        eprint("Unknown option: \(arg). Use --help for usage.")
        exit(1)
    }
}

let piping = isatty(STDOUT_FILENO) == 0

// MARK: - Resolve mic device

let micDevice: AVCaptureDevice
if let query = deviceQuery {
    guard let device = findDevice(matching: query) else {
        eprint("No input device matching \"\(query)\".")
        eprint("Available devices:")
        for device in discoverInputDevices() {
            eprint("  \(device.localizedName)")
        }
        exit(1)
    }
    micDevice = device
} else {
    guard let device = AVCaptureDevice.default(for: .audio) else {
        eprint("No audio input device found.")
        exit(1)
    }
    micDevice = device
}

// MARK: - Setup

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
let timestamp = formatter.string(from: Date())
let sanitizedLabel = label.map { $0.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression) }
let prefix = [timestamp, sanitizedLabel].compactMap({ $0 }).joined(separator: "_")
let outputURL = outputDir.appendingPathComponent("\(prefix).m4a")

let output: RecordingOutput
do {
    output = try RecordingOutput(fileURL: outputURL, pipeSampleRate: piping ? pipeRate : nil)
} catch {
    eprint("Failed to create output file: \(error.localizedDescription)")
    exit(1)
}

let mixer = AudioMixer { output.write($0) }
let systemExtractor = SampleExtractor()
let micExtractor = SampleExtractor()

func abort(_ message: String) -> Never {
    eprint(message)
    output.close()
    try? FileManager.default.removeItem(at: outputURL)
    exit(1)
}

// MARK: - Signal handling (Ctrl+C / kill)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

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

// MARK: - Start capture

eprint("Starting recording...")

let systemRecorder = SystemAudioRecorder { buffer, hostTime in
    if let samples = systemExtractor.samples(from: buffer) {
        mixer.append(samples, from: .system, at: hostTime)
    }
}
do {
    try await systemRecorder.start()
} catch {
    abort("""
    Failed to start system audio: \(error.localizedDescription)
    Grant Screen Recording permission in System Settings → Privacy & Security.
    """)
}

let micRecorder = MicRecorder { buffer, hostTime in
    if let samples = micExtractor.samples(from: buffer) {
        mixer.append(samples, from: .mic, at: hostTime)
    }
}
do {
    try micRecorder.start(device: micDevice)
} catch {
    try? await systemRecorder.stop()
    abort("""
    Failed to start microphone: \(error.localizedDescription)
    Grant Microphone permission in System Settings → Privacy & Security.
    """)
}

// MARK: - Recording

let startTime = Date()
eprint("Recording started at \(DateFormatter.localizedString(from: startTime, dateStyle: .none, timeStyle: .short))")
eprint("  Microphone: \(micDevice.localizedName)")
eprint("  File:       \(outputURL.path)")
if piping {
    eprint("  Stdout:     s16le mono \(Int(pipeRate)) Hz")
}
eprint("Press Ctrl+C to stop.")

for await _ in stopSignal { break }

// MARK: - Stop

let elapsed = Int(Date().timeIntervalSince(startTime))

eprint("\nStopping...")
micRecorder.stop()
try? await systemRecorder.stop()
mixer.finish()
output.close()

let h = elapsed / 3600
let m = (elapsed % 3600) / 60
let s = elapsed % 60
let duration = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)

eprint("Saved (\(duration))")
eprint("  \(outputURL.path)")
