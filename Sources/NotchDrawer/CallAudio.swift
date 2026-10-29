import AVFoundation
import ScreenCaptureKit
import Speech

/// Звук из колонок/наушников Mac (то, что говорят собеседники в Zoom) через ScreenCaptureKit.
/// Видео не нужно, поэтому картинка 2×2 пикселя раз в секунду, а звук — 16 кГц моно.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onStop: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "glaz.call.system-audio")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CallError("Не нашла экран для записи звука")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer), let buffer = Self.pcm(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async {
            self.stream = nil
            self.onStop?(message)
        }
    }

    private static func pcm(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Микрофон Mac: мой голос (и всё вокруг, если собеседники звучат из колонок).
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let engine = AVAudioEngine()

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CallError("Микрофон не найден")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Распознаёт речь одного источника (собеседники или я) и режет её на реплики:
/// пауза ~1.3 секунды — реплика закончилась. Каждые ~50 секунд распознавание
/// перезапускается, потому что у Apple есть ограничение на длину одного запроса.
final class LiveTranscriber {
    // Все три вызываются на главном потоке.
    /// Текст, который ещё распознаётся (меняется на ходу). Пустая строка — реплика закончилась.
    var onPartial: ((String) -> Void)?
    /// Готовая реплика.
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "glaz.call.transcriber")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var lastText = ""
    private var lastChange = Date()
    private var startedAt = Date()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var reportedError = false

    init(locale: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            restart()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.4, repeating: 0.4)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            let text = lastText
            lastText = ""
            generation += 1
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
            emitPartial("")
            if !text.trimmed.isEmpty { emitFinal(text) }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.request?.append(buffer) }
    }

    // Всё ниже вызывается только на queue.

    private func restart() {
        generation += 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lastText = ""
        startedAt = Date()
        guard running, let recognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let gen = generation
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async { self.handle(gen, result, error) }
        }
    }

    private func handle(_ gen: Int, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard gen == generation, running else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if text != lastText {
                lastText = text
                lastChange = Date()
                emitPartial(text)
            }
            if result.isFinal { commit() }
            return
        }
        if let error {
            if lastText.trimmed.isEmpty {
                // «Речи не было» и похожие ошибки: тихо перезапускаемся, но не чаще раза в секунду.
                let nsError = error as NSError
                if !reportedError, nsError.domain != "kAFAssistantErrorDomain" {
                    reportedError = true
                    let message = error.localizedDescription
                    DispatchQueue.main.async { self.onError?(message) }
                }
                generation += 1
                let next = generation
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == next else { return }
                    self.restart()
                }
            } else {
                commit()
            }
        }
    }

    private func emitPartial(_ text: String) {
        DispatchQueue.main.async { self.onPartial?(text) }
    }

    private func emitFinal(_ text: String) {
        DispatchQueue.main.async { self.onFinal?(text) }
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        if !lastText.trimmed.isEmpty, now.timeIntervalSince(lastChange) > 1.3 {
            commit()
        } else if now.timeIntervalSince(startedAt) > 50 {
            commit()
        }
    }

    private func commit() {
        let text = lastText
        restart()
        emitPartial("")
        if !text.trimmed.isEmpty { emitFinal(text) }
    }
}

enum CallPermissions {
    /// Распознавание речи. true — можно.
    static func speech() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    static func microphone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

struct CallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
