import AVFoundation
import AppKit
import Speech
import SwiftUI

// Assistant state shared by the chat dock, sidebar and command palette:
// chat with retrieval over your notes, photo OCR auto-sorting, and voice
// recording turned into a summarised note.
//
// Ported from src/components/assistant.tsx. Where the web version reaches for a
// browser API, the Mac app uses the native one: NSOpenPanel instead of a file
// input, AVAudioRecorder instead of MediaRecorder, and SFSpeechRecognizer
// instead of the Web Speech API.

struct UIMessage: Identifiable, Equatable {
    let id = UUID()
    var role: ChatMessage.Role
    var content: String
    var filed: [String] = []
    /// Same order as `filed`: where each item landed, for "Show" buttons.
    var links: [ChangeLink?] = []
    var imageThumb: Data?
    var isError = false
    /// A receipt just filed -> offer "split this bill".
    var splitTxId: String?
    /// Where an assistant reply was worked out.
    var origin: ReplyOrigin = .cloud
    /// A reply about one of the user's notes: offers to look further on the web.
    var webTopic: WebTopic?
    /// The pages a web answer drew on.
    var sources: [WebAnswer.Source] = []
    /// Who answered: "Claude", "OpenRouter", "LM Studio"…
    var answererName: String?
    /// "OpenRouter couldn't answer (key rejected), so Apple Intelligence stepped in."
    var fallbackNote: String?
    /// A reply this Mac wrote that a cloud model could do better — offered,
    /// never sent without the tap.
    var cloudOffer: CloudOffer?
    /// Saved to Notes already, so "Save as note" isn't offered again.
    var savedAsNote = false
    /// The user message this reply answers — the real question, not a "yes"
    /// or "Yes, ask OpenRouter" in between. Titles a saved reply.
    var questionId: UUID?

    /// A reply worth keeping: long, and not itself a record of what was filed.
    var canSaveAsNote: Bool {
        role == .assistant && !isError && !savedAsNote && filed.isEmpty && ReplyNote.isWorthSaving(content)
    }
}

/// "Ask OpenRouter" under a local reply: which question, and who would answer.
struct CloudOffer: Equatable {
    var questionId: UUID
    var name: String
}

/// The note a question was about, and what was asked of it.
struct WebTopic: Equatable {
    var noteId: String
    var noteTitle: String
    var question: String
}

@MainActor
final class Assistant: ObservableObject {
    @Published private(set) var messages: [UIMessage] = []
    /// Label of the running job, or nil when idle.
    @Published private(set) var busy: String?
    @Published private(set) var recording = false
    @Published private(set) var liveTranscript = ""
    /// Set when dictation permission is refused: recording still works, the live text does not.
    @Published private(set) var transcriptionUnavailable = false
    /// Held between the record button and the microphone actually opening.
    private(set) var startingRecording = false
    /// Recording, or about to: the microphone is spoken for.
    var micBusy: Bool { recording || startingRecording }

    private unowned let store: Store
    private let nav: Navigation
    private let toasts: ToastCenter
    private let engine: AIEngine

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioEngine: AVAudioEngine?

    init(store: Store, nav: Navigation, toasts: ToastCenter, engine: AIEngine) {
        self.store = store
        self.nav = nav
        self.toasts = toasts
        self.engine = engine
        Self.removeOrphanedRecordings()
    }

    /// A recording's file is deleted once it has been written up, but a crash
    /// or force-quit mid-recording leaves it behind — eleven had piled up from
    /// the crash on Record. Nothing records across launches, so any found at
    /// startup belong to nobody.
    private static func removeOrphanedRecordings() {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in files where name.hasPrefix("fournotes-") && name.hasSuffix(".m4a") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func clear() { messages.removeAll() }

    // MARK: - Chat

    @discardableResult
    func send(_ text: String) async -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, busy == nil else { return nil }

        // The reply above asked "Want me to look this up online?": a yes is
        // the tap on it; anything else lets the offer lapse.
        let pendingOffer = messages.last(where: { $0.role == .assistant })?.cloudOffer
        for i in messages.indices where messages[i].cloudOffer != nil { messages[i].cloudOffer = nil }

        let question = UIMessage(role: .user, content: clean)
        messages.append(question)

        if let pendingOffer, Intent.agrees(clean) {
            await askCloud(pendingOffer, answering: question.id)
            return nil
        }

        // "save that": the reply above, saved as shown. No model rewrites it.
        // Also "yes" to a reply that offered to save itself.
        if let previous = messages.dropLast().last(where: { $0.role == .assistant && !$0.isError }),
           previous.canSaveAsNote,
           Intent.savesPreviousReply(clean) || (Intent.agrees(clean) && ReplyNote.offersToSave(previous.content)) {
            saveAsNote(previous.id)
            return nil
        }
        busy = engine.chatRunsOnDevice ? "Thinking on this Mac…" : "Thinking…"
        defer { busy = nil }

        do {
            // Notes the message names outright go to the assistant in full.
            let relevant = Search.relevantNotes(for: clean, in: store.liveNotes,
                                                openNoteId: nav.selectedNoteId)
            // Error notices are ours, not the assistant's: sending them back as
            // conversation history teaches it to talk about API keys.
            let history = messages.filter { !$0.isError }.suffix(12)
                .map { ChatMessage(role: $0.role, content: $0.content) }
            // A question or a request for ideas is answered, never filed.
            let response = try await engine.chat(history, context: store.buildContext(relevantNotes: relevant),
                                                 tools: !Intent.answerOnly(clean))
            // A question about a note is answered, never filed: the model
            // used to save the note again under the same title.
            let about = Intent.noteQuestion(clean).flatMap { q in
                store.liveNotes.first { $0.title.caseInsensitiveCompare(q.title) == .orderedSame }
                    .map { WebTopic(noteId: $0.id, noteTitle: $0.title, question: q.ask) }
            }
            // Amounts are checked against the message whichever model answered.
            var actions = Intent.ground(response.actions, in: clean)
            if about != nil, Intent.isQuestion(clean) { actions = [] }
            let result = store.applyActions(actions)
            nav.markFiled(result.created)

            var reply = UIMessage(role: .assistant, content: ModelText.withoutToolLabels(response.reply))
            // A reply that says "logged Rp 128,500" while nothing was stored is
            // worse than an error, because the user believes their finances are
            // up to date.
            if response.droppedActions > 0 {
                let count = response.droppedActions
                reply.content += "\n\n⚠️ \(count) \(count == 1 ? "change" : "changes") could not be "
                    + "saved — check the tab before relying on this."
                reply.isError = true
            }
            reply.filed = result.filed
            reply.links = result.links
            reply.splitTxId = result.transactionIds.first
            reply.origin = response.answeredBy
            reply.answererName = response.answererName
            reply.fallbackNote = response.fallbackNote
            reply.questionId = question.id
            reply.webTopic = about
            // Answered here, but a bigger model knows more of the world:
            // recommendations, ideas, a question about a note, or one the
            // local model said was beyond it.
            // Not for something the cloud would refuse outright.
            if let cloud = engine.cloudOffer, response.answeredBy != .cloud, !response.refused, result.created.isEmpty,
               Guard.blockedReply(clean, tier: .cloud) == nil,
               Intent.needsCloud(clean, localReply: response.reply, aboutNote: about != nil) {
                reply.cloudOffer = CloudOffer(questionId: question.id, name: cloud)
            }
            messages.append(reply)
            return response.reply
        } catch {
            var failed = UIMessage(role: .assistant, content: message(for: error), isError: true)
            // This Mac couldn't answer; the cloud might — if the user says so.
            if let cloud = engine.cloudOffer { failed.cloudOffer = CloudOffer(questionId: question.id, name: cloud) }
            messages.append(failed)
            return nil
        }
    }

    /// Saves an assistant reply to Notes exactly as it was shown, titled from
    /// the question that led to it.
    func saveAsNote(_ replyId: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == replyId }) else { return }
        let reply = messages[index]
        let question = reply.questionId.flatMap { id in messages.first { $0.id == id }?.content }
            ?? messages[..<index].last(where: { $0.role == .user && !Intent.agrees($0.content) })?.content
        let title = ReplyNote.title(reply: reply.content, question: question)
        let result = store.applyActions([.createNote(title: title,
                                                     content: ReplyNote.content(fromReply: reply.content),
                                                     tags: [], ref: nil)])
        nav.markFiled(result.created)
        messages[index].savedAsNote = true

        var confirmation = UIMessage(role: .assistant, content: "Saved it to Notes, as written.")
        confirmation.filed = result.filed
        confirmation.links = result.links
        confirmation.origin = .onDevice
        confirmation.answererName = "Four Notes"
        messages.append(confirmation)
    }

    /// The question behind `offer`, answered by the cloud model. Answer only:
    /// whatever the message asked to file was filed on this Mac already.
    /// `answering`: the "yes" that accepted, when it was typed rather than tapped.
    func askCloud(_ offer: CloudOffer, answering: UUID? = nil) async {
        guard busy == nil, let index = messages.firstIndex(where: { $0.id == offer.questionId }) else { return }
        // One tap per offer.
        for i in messages.indices where messages[i].cloudOffer == offer { messages[i].cloudOffer = nil }
        if answering == nil {
            // Tapped: show it as the user's answer to the question asked.
            messages.append(UIMessage(role: .user, content: "Yes, ask \(offer.name)"))
        }
        busy = "Asking \(offer.name)…"
        defer { busy = nil }

        let question = messages[index].content
        let history = messages[...index].filter { !$0.isError }.suffix(12)
            .map { ChatMessage(role: $0.role, content: $0.content) }
        do {
            let relevant = Search.relevantNotes(for: question, in: store.liveNotes, openNoteId: nav.selectedNoteId)
            let response = try await engine.chatInCloud(Array(history),
                                                        context: store.buildContext(relevantNotes: relevant))
            var reply = UIMessage(role: .assistant, content: response.reply)
            reply.origin = .cloud
            reply.answererName = response.answererName ?? offer.name
            reply.questionId = offer.questionId
            messages.append(reply)
        } catch {
            messages.append(UIMessage(role: .assistant, content: message(for: error), isError: true))
        }
    }

    // MARK: - The web

    /// The note's subject in the user's own browser. Nothing is sent anywhere
    /// but the search engine, and only the words below.
    func openWebSearch(_ topic: WebTopic) {
        let words = topic.question.isEmpty ? topic.noteTitle : "\(topic.noteTitle) \(topic.question)"
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: words)]
        if let link = url.url { NSWorkspace.shared.open(link) }
    }

    /// Recommendations from the web for a note, in the chat, with sources.
    func searchWeb(_ topic: WebTopic) async {
        guard busy == nil, let note = store.liveNotes.first(where: { $0.id == topic.noteId }) else { return }
        messages.append(UIMessage(role: .user, content: "Ideas from the web for “\(topic.noteTitle)”"))
        busy = "Searching the web…"
        defer { busy = nil }
        do {
            let answer = try await engine.webIdeas(title: note.title, content: note.content,
                                                   question: topic.question)
            var reply = UIMessage(role: .assistant, content: answer.text)
            reply.sources = answer.sources
            messages.append(reply)
        } catch {
            messages.append(UIMessage(role: .assistant, content: message(for: error), isError: true))
        }
    }

    // MARK: - Scan

    /// Pick an image and let the assistant decide where it belongs.
    func pickAndScan() {
        guard busy == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a receipt, a handwritten page or a checklist."
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        Task { await scan(image) }
    }

    func scan(_ image: NSImage, source: NoteSource = .ocr) async {
        guard busy == nil else {
            toasts.push("The assistant is still \(busy ?? "busy") — try again in a moment.", tone: .error)
            return
        }
        busy = "Reading…"
        defer { busy = nil }

        guard let full = ImageKit.jpeg(image, maxSide: 1600, quality: 0.85),
              let thumb = ImageKit.jpeg(image, maxSide: 320, quality: 0.6) else {
            toasts.push("That image could not be read.", tone: .error)
            return
        }

        var shown = UIMessage(role: .user, content: "Scanned an image")
        shown.imageThumb = thumb
        messages.append(shown)

        do {
            let result = try await engine.scan(image, jpeg: full, context: store.buildContext())
            // Only create the file when an action in this result can reference
            // it; a parser rejection otherwise left an unreferenced thumbnail.
            let storesImage = result.actions.contains { action in
                switch action {
                case .createNote, .addTransaction: return true
                default: return false
                }
            }
            let file = storesImage ? Attachments.save(thumb) : nil
            let applied = store.applyActions(result.actions, imageFile: file, source: source)
            nav.markFiled(applied.created)

            var reply = UIMessage(role: .assistant, content: result.reply)
            reply.filed = applied.filed
            reply.links = applied.links
            reply.splitTxId = applied.transactionIds.first
            messages.append(reply)

            if let first = applied.created.first { nav.open(first) }
        } catch {
            messages.append(UIMessage(role: .assistant, content: message(for: error), isError: true))
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !recording, !startingRecording, busy == nil else { return }
        // The edge dock's dictation holds the microphone too; one at a time.
        guard !QuickTranscriber.shared.isActive else {
            toasts.push("Dictation is running in the edge dock. Stop it first.", tone: .error)
            return
        }
        // Claim the microphone synchronously: the permission check below is an
        // await, and two clicks either side of it both used to get through.
        startingRecording = true
        Task {
            defer { startingRecording = false }
            guard await requestMicrophone() else {
                toasts.push("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.",
                            tone: .error)
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fournotes-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.record()
                self.recorder = recorder
                self.recordingURL = url
                self.recording = true
                self.liveTranscript = ""
                self.transcriptionUnavailable = false
                startLiveTranscription()
            } catch {
                toasts.push("Could not start recording: \(error.localizedDescription)", tone: .error)
            }
        }
    }

    func stopRecording() {
        guard recording else { return }
        recorder?.stop()
        recording = false
        stopLiveTranscription()

        let transcript = liveTranscript
        let url = recordingURL
        recorder = nil
        recordingURL = nil

        // Claim `busy` here, not inside the task: otherwise there is a gap where
        // recording is false and busy is nil, a second recording can start, and
        // this job's cleanup then clears the other one's state.
        busy = "Writing it up…"
        Task { await finishRecording(url: url, transcript: transcript) }
    }

    private func finishRecording(url: URL?, transcript: String) async {
        defer {
            busy = nil
            liveTranscript = ""
            if let url { try? FileManager.default.removeItem(at: url) }
        }

        let audio = url.flatMap { try? Data(contentsOf: $0) }
        guard audio != nil || !transcript.isEmpty else {
            toasts.push("That recording was empty.", tone: .error)
            return
        }

        messages.append(UIMessage(role: .user,
                                  content: transcript.isEmpty ? "Recorded a voice note" : transcript))
        do {
            let result = try await engine.summarizeRecording(transcript, audio: audio,
                                                             context: store.buildContext())
            let applied = store.applyActions(result.actions, source: .recording)
            nav.markFiled(applied.created)

            var reply = UIMessage(role: .assistant, content: result.reply)
            reply.filed = applied.filed
            reply.links = applied.links
            messages.append(reply)

            if let first = applied.created.first { nav.open(first) }
        } catch {
            messages.append(UIMessage(role: .assistant, content: message(for: error), isError: true))
        }
    }

    /// A transcript from the edge dock's dictation, written up into notes and
    /// tasks the way a recording is — but without switching the window's tab,
    /// which may be behind another app. Returns what was filed, or nil.
    func writeUp(_ transcript: String) async -> UIMessage? {
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, busy == nil else { return nil }
        busy = "Writing it up…"
        defer { busy = nil }
        messages.append(UIMessage(role: .user, content: clean))
        do {
            let result = try await engine.summarizeRecording(clean, audio: nil, context: store.buildContext())
            let applied = store.applyActions(result.actions, source: .recording)
            nav.markFiled(applied.created)
            var reply = UIMessage(role: .assistant, content: result.reply)
            reply.filed = applied.filed
            reply.links = applied.links
            messages.append(reply)
            return reply
        } catch {
            let failed = UIMessage(role: .assistant, content: message(for: error), isError: true)
            messages.append(failed)
            return failed
        }
    }

    // MARK: - Live transcription (native, no server round trip)

    private func startLiveTranscription() {
        Task {
            // Requesting this without NSSpeechRecognitionUsageDescription in
            // Info.plist terminates the process, so the key must stay in place.
            let status = await Self.speechAuthorization()
            guard status == .authorized else {
                // The recording itself still works; only the live text is lost.
                transcriptionUnavailable = true
                return
            }
            // Stopped while the permission prompt was up: opening the
            // microphone now would leave it on with nothing to close it.
            guard recording else { return }
            beginSpeechCapture()
        }
    }

    private func beginSpeechCapture() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the audio on this Mac when the recognizer can manage it.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        // Named `capture` so it is not confused with the app's AI engine.
        let capture = AVAudioEngine()
        guard Self.feed(capture.inputNode, into: request) else {
            transcriptionUnavailable = true
            return
        }
        do {
            capture.prepare()
            try capture.start()
        } catch {
            capture.inputNode.removeTap(onBus: 0)
            transcriptionUnavailable = true
            return
        }
        audioEngine = capture
        speechRequest = request
        speechTask = Self.transcribe(request, with: recognizer) { [weak self] text in
            Task { @MainActor in self?.liveTranscript = text }
        }
    }

    // MARK: Callbacks that arrive off the main thread
    //
    // Speech and audio call back on their own threads: the permission answer
    // and recognition results on background queues, the microphone tap on the
    // real-time audio thread. A closure written inside this @MainActor class is
    // itself main-actor-isolated, and Swift 6 checks that at runtime — so the
    // first callback stopped the app (EXC_BREAKPOINT in
    // _dispatch_assert_queue_fail), every time Record was pressed. The compiler
    // cannot see which thread an Objective-C callback runs on, so it never
    // complained. These closures are made in nonisolated functions instead,
    // and only hop to the main actor for the one property they update.

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Streams microphone buffers into the recognizer. False when there is no
    /// usable input — installing a tap with an empty format raises an
    /// Objective-C exception, which nothing can catch.
    nonisolated private static func feed(_ input: AVAudioInputNode,
                                         into request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        // The request is only appended to from the tap once it is installed;
        // Speech documents `append` as safe to call from the audio thread.
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        return true
    }

    nonisolated private static func transcribe(_ request: SFSpeechAudioBufferRecognitionRequest,
                                               with recognizer: SFSpeechRecognizer,
                                               onText: @escaping @Sendable (String) -> Void)
        -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, _ in
            guard let result else { return }
            onText(result.bestTranscription.formattedString)
        }
    }

    private func stopLiveTranscription() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        speechRequest?.endAudio()
        speechRequest = nil
        speechTask?.cancel()
        speechTask = nil
    }

    private func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Errors

    private func message(for error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "Something went wrong." }
        return error.localizedDescription
    }
}

// MARK: - Image helpers

enum ImageKit {
    /// Downscale a photo before upload: faster, cheaper, and still readable for OCR.
    static func jpeg(_ image: NSImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let scale = min(1, maxSide / max(width, height))
        let size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())

        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: scaled)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func image(fromDataUrl dataUrl: String?) -> NSImage? {
        guard let dataUrl, let comma = dataUrl.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }
}
