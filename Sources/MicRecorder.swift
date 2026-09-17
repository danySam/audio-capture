import Foundation
import AVFoundation
import CoreMedia

final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "audio-capture.mic")
    private var session: AVCaptureSession?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    func start(to url: URL, device: AVCaptureDevice) throws {
        let captureSession = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        captureSession.addOutput(output)

        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
        ])
        writerInput.expectsMediaDataInRealTime = true
        writer.add(writerInput)

        self.assetWriter = writer
        self.audioInput = writerInput
        self.session = captureSession

        captureSession.startRunning()
    }

    func stop() async {
        session?.stopRunning()
        session = nil

        audioQueue.sync {}

        audioInput?.markAsFinished()
        if let writer = assetWriter, writer.status == .writing {
            await writer.finishWriting()
        }
        assetWriter = nil
        audioInput = nil
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer = assetWriter, let input = audioInput else { return }

        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }

        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
