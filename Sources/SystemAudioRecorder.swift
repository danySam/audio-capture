import Foundation
import ScreenCaptureKit
import CoreMedia

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "audio-capture.system")
    private let onBuffer: (CMSampleBuffer, CMTime) -> Void
    private var stream: SCStream?

    init(onBuffer: @escaping (CMSampleBuffer, CMTime) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = Int(AudioMixer.sampleRate)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        if let stream {
            try await stream.stopCapture()
            self.stream = nil
        }
        audioQueue.sync {}
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onBuffer(sampleBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        eprint("System audio error: \(error.localizedDescription)")
    }
}

enum CaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        }
    }
}
