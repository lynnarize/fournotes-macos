import AVFoundation
import Foundation
import Speech

// Dictation for the edge dock: speak, watch the words and the levels arrive,
// then keep the text. Unlike Record (Assistant), nothing is sent to a model
// and nothing is filed until asked — it is a transcript, not a write-up.
//
// Everything stays on this Mac when the recognizer can manage it.

@MainActor
final class QuickTranscriber: ObservableObject {
    static let shared = QuickTranscriber()

    enum Phase: Equatable {
        case idle, starting, listening, finishing, done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The words so far; editable once listening has finished.
    @Published var text = ""
    /// Recent input levels, 0…1, oldest first — what the visualizer draws.
    @Published private(set) var levels = [Float](repeating: 0, count: QuickTranscriber.levelCount)
    @Published private(set) var startedAt: Date?
    /// The language being listened for, as a locale identifier.
    @Published var localeId: String {
        didSet { UserDefaults.standard.set(localeId, forKey: Self.localeKey) }
    }

    nonisolated static let levelCount = 44
    private static let localeKey = "fournotes.transcribeLocale"

    private var capture: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    /// The request the microphone feeds. Swapped when the recognizer ends a
    /// session early — server recognition stops after about a minute — so
    /// listening carries on instead of silently dropping every later word.
    private let feed = RequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { feed.request }
        set { feed.request = newValue }
    }
    /// Words from sessions that already ended, and from segments the
    /// recognizer has moved on from.
    private var committed = ""
    /// The last partial result of the current segment.
    private var lastPartial = ""
    /// When the last session began: one ending within seconds of starting is
    /// an error, not a time limit, and restarting it would only loop.
    private var sessionStarted = Date.distantPast
    private var task: SFSpeechRecognitionTask?
    /// Bumped on every start, so callbacks from an earlier session are ignored.
    private var session = 0
    private var finishTimeout: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?

    var isActive: Bool { phase == .starting || phase == .listening || phase == .finishing }

    private init() {
        localeId = UserDefaults.standard.string(forKey: Self.localeKey) ?? Locale.current.identifier
    }

    // MARK: - Languages

    /// The languages worth offering: this Mac's, English and Indonesian, and
    /// whatever was picked before — each only if the recognizer has it.
    var languages: [(id: String, name: String)] {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        var seen = Set<String>()
        return [localeId, Locale.current.identifier, "en-US", "en-GB", "id-ID"]
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { id in supported.contains(id) || supported.contains(id.replacingOccurrences(of: "-", with: "_")) }
            .filter { seen.insert($0).inserted }
            .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
    }

    var languageName: String {
        Locale.current.localizedString(forIdentifier: localeId) ?? localeId
    }

    // MARK: - Start and stop

    func start() {
        guard !isActive else { return }
        // Record (in the sidebar) holds the microphone too; one at a time.
        guard !AppModel.shared.assistant.micBusy else {
            phase = .failed("A recording is already running. Stop it first.")
            return
        }
        session += 1
        let current = session
        phase = .starting
        text = ""
        levels = [Float](repeating: 0, count: Self.levelCount)
        Task {
            guard await Self.microphoneAllowed() else {
                fail("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.",
                     session: current)
                return
            }
            guard await Self.speechAuthorization() == .authorized else {
                fail("Speech recognition is off. Turn it on in System Settings → Privacy & Security → Speech Recognition.",
                     session: current)
                return
            }
            // Stopped while a permission prompt was up.
            guard session == current, phase == .starting else { return }
            begin(session: current)
        }
    }

    private func begin(session current: Int) {
        let locale = Locale(identifier: localeId)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            fail("Speech recognition isn't available for \(languageName) right now.", session: current)
            return
        }
        let engine = AVAudioEngine()
        let sink: @Sendable ([Float]) -> Void = { [weak self] chunk in
            Task { @MainActor in
                guard let self, self.session == current else { return }
                self.push(chunk)
            }
        }
        guard Self.tap(engine.inputNode, into: feed, levels: sink) else {
            fail("No microphone was found.", session: current)
            return
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            fail("Couldn't open the microphone: \(error.localizedDescription)", session: current)
            return
        }
        capture = engine
        // A microphone plugged in or taken away stops the engine without a
        // word; without this the card would say "Listening" to nothing.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session == current, self.phase == .listening else { return }
                self.stop()
            }
        }
        self.recognizer = recognizer
        committed = ""
        recognize(session: current)
        startedAt = Date()
        phase = .listening
    }

    /// Starts a recognition session on whatever the microphone hears next.
    private func recognize(session current: Int) {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        lastPartial = ""
        sessionStarted = Date()
        task = Self.recognize(request, with: recognizer) { [weak self] text, isFinal in
            Task { @MainActor in
                // After the timeout the text is the user's to edit: a result
                // that turns up later must not overwrite it.
                guard let self, self.session == current,
                      self.phase == .listening || self.phase == .finishing else { return }
                if !text.isEmpty {
                    // After a pause the recognizer may start a new segment and
                    // report only the words since — the transcript seemed to
                    // clear itself once it grew past the box. Keep what came
                    // before.
                    if Self.startsOver(previous: self.lastPartial, next: text) {
                        self.committed = Self.join(self.committed, self.lastPartial)
                    }
                    self.lastPartial = text
                    self.text = Self.join(self.committed, text)
                }
                guard isFinal else { return }
                if self.phase == .finishing {
                    self.finish()
                } else if self.phase == .listening {
                    guard Date().timeIntervalSince(self.sessionStarted) > 3 else {
                        self.stop()
                        return
                    }
                    // Ended early while still listening: keep what was
                    // heard and start another session.
                    self.committed = self.text
                    self.lastPartial = ""
                    self.recognize(session: current)
                }
            }
        }
    }

    /// Stops listening and waits briefly for the recognizer's last word.
    func stop() {
        switch phase {
        case .starting:
            // Still asking for permission: nothing is open yet.
            session += 1
            phase = .idle
        case .listening:
            phase = .finishing
            closeMicrophone()
            request?.endAudio()
            let current = session
            finishTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.session == current, self.phase == .finishing else { return }
                self.finish()
            }
        default:
            break
        }
    }

    /// Drops everything, including the text. Also used on quit.
    func cancel() {
        session += 1
        closeMicrophone()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finishTimeout?.cancel()
        text = ""
        startedAt = nil
        levels = [Float](repeating: 0, count: Self.levelCount)
        phase = .idle
    }

    private func finish() {
        finishTimeout?.cancel()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        startedAt = nil
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = text.isEmpty ? .failed("Nothing was heard. Check the microphone and try again.") : .done
    }

    private func fail(_ message: String, session current: Int) {
        guard session == current else { return }
        closeMicrophone()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        startedAt = nil
        phase = .failed(message)
    }

    private func closeMicrophone() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        capture?.inputNode.removeTap(onBus: 0)
        capture?.stop()
        capture = nil
    }

    private func push(_ chunk: [Float]) {
        guard phase == .listening, !chunk.isEmpty else { return }
        var next = levels
        next.append(contentsOf: chunk)
        levels = Array(next.suffix(Self.levelCount))
    }

    // MARK: - Joining segments

    /// True when `next` is a new segment rather than a revision of `previous`:
    /// shorter, and not beginning the way `previous` did. Revisions rewrite
    /// the last words, not the first ones.
    nonisolated static func startsOver(previous: String, next: String) -> Bool {
        let a = normalized(previous), b = normalized(next)
        // Clearly shorter, and starting with a different word. A revision
        // that rewrites "twenty" as "20" is shorter too, but keeps its first
        // word — joining it used to repeat the sentence.
        guard !a.isEmpty, !b.isEmpty, Double(b.count) < Double(a.count) * 0.7 else { return false }
        let firstA = a.split(separator: " ").first, firstB = b.split(separator: " ").first
        return firstA != firstB
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    private nonisolated static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Level math

    /// Loudness of `samples` as 0…1: RMS in decibels, -50 dB (a quiet room)
    /// to -8 dB (speaking close to the microphone), eased so speech fills
    /// the bars without pinning them.
    nonisolated static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        let t = min(1, max(0, (db + 50) / 42))
        return t.squareRoot()
    }

    // MARK: - Callbacks off the main thread
    //
    // The tap runs on the real-time audio thread and recognition results on a
    // background queue. Closures written inside this @MainActor class would be
    // main-actor-isolated and trap when called there (see Assistant), so they
    // are made in nonisolated functions and hop back only to publish.

    nonisolated private static func tap(_ input: AVAudioInputNode,
                                        into feed: RequestBox,
                                        levels: @escaping @Sendable ([Float]) -> Void) -> Bool {
        let format = input.outputFormat(forBus: 0)
        // Installing a tap with an empty format raises an exception nothing can catch.
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        // About 40 bars a second, whatever size the buffers arrive in.
        let slice = max(256, Int(format.sampleRate / 40))
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            feed.request?.append(buffer)
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var out: [Float] = []
            var start = 0
            while start < count {
                let n = min(slice, count - start)
                out.append(level(of: UnsafeBufferPointer(start: channel + start, count: n)))
                start += n
            }
            levels(out)
        }
        return true
    }

    nonisolated private static func recognize(_ request: SFSpeechAudioBufferRecognitionRequest,
                                              with recognizer: SFSpeechRecognizer,
                                              onText: @escaping @Sendable (String, Bool) -> Void)
        -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onText(result.bestTranscription.formattedString, result.isFinal)
            } else if error != nil {
                onText("", true)
            }
        }
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// The recognition request the audio thread appends to, swapped from the
/// main actor. Speech documents `append` as safe from the audio thread; the
/// lock only guards which request that is.
final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }
}
