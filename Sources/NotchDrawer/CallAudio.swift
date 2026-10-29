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

/// Распознавание речи одного источника (собеседники или я).
protocol SpeechTranscribing: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
}

enum Transcribers {
    /// На macOS 26 — новое распознавание Apple (SpeechAnalyzer): лучше слышит длинную речь
    /// и само делит её на фразы. На старых системах — SFSpeechRecognizer.
    static func make(locale: String) -> SpeechTranscribing {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return AnalyzerTranscriber(locale: locale) }
        #endif
        return LiveTranscriber(locale: locale)
    }
}

/// Распознаёт речь одного источника (собеседники или я) и режет её на реплики:
/// пауза ~1.8 секунды — реплика закончилась. Каждые ~50 секунд распознавание
/// перезапускается, потому что у Apple есть ограничение на длину одного запроса.
final class LiveTranscriber: SpeechTranscribing {
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
        if !lastText.trimmed.isEmpty, now.timeIntervalSince(lastChange) > 1.8 {
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

#if compiler(>=6.2)
/// SpeechAnalyzer + SpeechTranscriber (macOS 26). Если не завёлся (нет языка, не скачалась модель),
/// тихо переключаемся на LiveTranscriber.
@available(macOS 26.0, *)
final class AnalyzerTranscriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let localeID: String
    private let lock = NSLock()
    private var builder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var fallback: LiveTranscriber?
    private var stopped = false

    init(locale: String) {
        localeID = locale
    }

    func start() {
        Task { [self] in
            do {
                try await setUp()
            } catch {
                NSLog("SpeechAnalyzer: \(error)")
                let live = LiveTranscriber(locale: localeID)
                live.onPartial = onPartial
                live.onFinal = onFinal
                live.onError = onError
                if useFallback(live) { live.start() }
            }
        }
    }

    private func setUp() async throws {
        let supported: Locale? = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID))
        guard let locale = supported else {
            throw CallError("Язык не поддерживается новым распознаванием")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            DispatchQueue.main.async { self.onError?("Скачиваю модель распознавания речи, это один раз…") }
            try await request.downloadAndInstall()
            DispatchQueue.main.async { self.onError?("Модель скачана, слушаю") }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let best: AVAudioFormat? = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        guard let format = best else {
            throw CallError("Нет подходящего формата звука")
        }
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmed
                    let isFinal = result.isFinal
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if isFinal {
                            self.onPartial?("")
                            if !text.isEmpty { self.onFinal?(text) }
                        } else {
                            self.onPartial?(text)
                        }
                    }
                }
            } catch {
                let message = error.localizedDescription
                guard let self else { return }
                DispatchQueue.main.async { self.onError?("Распознавание: \(message)") }
            }
        }
        try await analyzer.start(inputSequence: stream)

        if !install(analyzer, format, builder) {
            builder.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    /// false — пока заводились, запись уже остановили.
    private func install(_ analyzer: SpeechAnalyzer, _ format: AVAudioFormat,
                         _ builder: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.analyzer = analyzer
        self.format = format
        self.builder = builder
        return true
    }

    private func useFallback(_ live: LiveTranscriber) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        fallback = live
        return true
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let fallback {
            fallback.append(buffer)
            return
        }
        guard let builder, let format, let converted = convert(buffer, to: format) else { return }
        builder.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        lock.lock()
        stopped = true
        let builder = self.builder
        let analyzer = self.analyzer
        let fallback = self.fallback
        self.builder = nil
        self.analyzer = nil
        lock.unlock()
        fallback?.stop()
        builder?.finish()
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
    }

    /// SpeechAnalyzer хочет свой формат (обычно 16 кГц моно), а звук приходит в каком угодно.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }
}
#endif

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
