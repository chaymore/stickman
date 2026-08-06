import AVFoundation
import Foundation

enum RealtimeAudioError: LocalizedError {
    case microphoneDenied
    case invalidInputFormat
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Stickman needs microphone permission before voice mode can start."
        case .invalidInputFormat:
            return "Stickman could not read your microphone's audio format."
        case .audioEngineFailed(let message):
            return "Stickman could not start voice audio: \(message)"
        }
    }
}

final class RealtimeAudioIOController {
    static let sampleRate: Double = 24_000

    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "stickman.realtime.audio")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: RealtimeAudioIOController.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var isPlayerAttached = false
    private var isCapturing = false
    private var onAudioChunk: ((String) -> Void)?

    func start(onAudioChunk: @escaping (String) -> Void) async throws {
        let granted = await requestMicrophoneAccess()
        guard granted else {
            throw RealtimeAudioError.microphoneDenied
        }

        self.onAudioChunk = onAudioChunk
        try startOutput()
        try startInput()
    }

    func stop() {
        isCapturing = false
        inputEngine.inputNode.removeTap(onBus: 0)
        inputEngine.stop()
        playerNode.stop()
        outputEngine.stop()
        onAudioChunk = nil
        converter = nil
    }

    func stopPlayback() {
        playerNode.stop()
        if outputEngine.isRunning {
            playerNode.play()
        }
    }

    func playPCM16(base64Audio: String) {
        guard let data = Data(base64Encoded: base64Audio), !data.isEmpty else { return }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ),
              let channel = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0 ..< sampleCount {
                channel[index] = Float(Int16(littleEndian: samples[index])) / Float(Int16.max)
            }
        }

        audioQueue.async { [weak self] in
            self?.playerNode.scheduleBuffer(buffer)
            if self?.playerNode.isPlaying == false {
                self?.playerNode.play()
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startOutput() throws {
        if !isPlayerAttached {
            outputEngine.attach(playerNode)
            isPlayerAttached = true
        }

        outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: targetFormat)

        do {
            try outputEngine.start()
            playerNode.play()
        } catch {
            throw RealtimeAudioError.audioEngineFailed(error.localizedDescription)
        }
    }

    private func startInput() throws {
        let inputNode = inputEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioError.invalidInputFormat
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RealtimeAudioError.invalidInputFormat
        }

        self.converter = converter
        isCapturing = true

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        inputEngine.prepare()

        do {
            try inputEngine.start()
        } catch {
            throw RealtimeAudioError.audioEngineFailed(error.localizedDescription)
        }
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing, let converter else { return }

        audioQueue.async { [weak self] in
            guard let self, self.isCapturing else { return }
            let ratio = RealtimeAudioIOController.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 8))
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else {
                return
            }

            var didProvideInput = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                status.pointee = .haveData
                return buffer
            }

            guard conversionError == nil,
                  converted.frameLength > 0,
                  let channel = converted.floatChannelData?[0] else {
                return
            }

            var pcmData = Data(capacity: Int(converted.frameLength) * MemoryLayout<Int16>.size)
            for index in 0 ..< Int(converted.frameLength) {
                let clipped = max(-1, min(1, channel[index]))
                let value = Int16(clipped < 0 ? clipped * 32768 : clipped * 32767)
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes in
                    pcmData.append(contentsOf: bytes)
                }
            }

            self.onAudioChunk?(pcmData.base64EncodedString())
        }
    }
}
