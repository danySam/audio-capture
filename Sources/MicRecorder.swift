import Foundation
import AVFoundation
import CoreMedia

final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let audioQueue = DispatchQueue(label: "audio-capture.mic")
    private let onBuffer: (CMSampleBuffer, CMTime) -> Void
    private var session: AVCaptureSession?
    private var clock: CMClock?

    init(onBuffer: @escaping (CMSampleBuffer, CMTime) -> Void) {
        self.onBuffer = onBuffer
    }

    func start(device: AVCaptureDevice) throws {
        let captureSession = AVCaptureSession()
        captureSession.addInput(try AVCaptureDeviceInput(device: device))

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        captureSession.addOutput(output)

        clock = captureSession.synchronizationClock
        session = captureSession
        captureSession.startRunning()
    }

    func stop() {
        session?.stopRunning()
        session = nil
        audioQueue.sync {}
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = sampleBuffer.presentationTimeStamp
        // Capture-session timestamps are on the session clock; the mixer aligns everything on host time.
        let hostTime = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        onBuffer(sampleBuffer, hostTime)
    }
}
