import AVFoundation
import Foundation
import Testing
@testable import FourNotes

// Downloads real speech models from Hugging Face, pauses and resumes the download,
// and transcribes speech made here with the system voices. It fetches about 110 MB,
// so it is off by default; on with:
//
//   TEST_RUNNER_FOURNOTES_EVAL_SPEECH=1 ./scripts/run-tests.sh

private let enabled = ProcessInfo.processInfo.environment["FOURNOTES_EVAL_SPEECH"] == "1"

/// Whisper tiny: the same files and loading as large-v3 turbo, at an eighth of the size.
private let tiny = SpeechModels.Pack(
    id: "test-whisper-tiny", kind: .whisper, name: "Whisper tiny", detail: "", icon: "mic", approxBytes: 77_000_000,
    sources: [
        SpeechModels.Source(repo: "argmaxinc/whisperkit-coreml", path: "openai_whisper-tiny"),
        SpeechModels.Source(repo: "openai/whisper-tiny", path: "",
                            only: ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json"]),
    ])

@Suite("Speech models", .serialized, .enabled(if: enabled))
@MainActor
struct SpeechModelsTests {
    private let models = SpeechModels.shared

    @Test("A download pauses, resumes where it stopped, checks its files and installs")
    func downloadPauseResume() async throws {
        models.cancel(tiny)
        models.delete(tiny)
        models.download(tiny)
        try await waitUntil(seconds: 180) { models.status(tiny).received > 8_000_000 }
        models.pause(tiny)
        try await waitUntil(seconds: 30) { models.status(tiny).phase == .paused }
        let kept = models.status(tiny).received
        print("SPEECH | paused at \(SpeechModels.size(kept)) of \(SpeechModels.size(models.status(tiny).total ?? 0))")
        #expect(kept > 8_000_000)

        models.download(tiny)
        try await waitUntil(seconds: 60) { models.status(tiny).received >= kept && models.status(tiny).phase == .downloading }
        // Resumed, not restarted: it never went back below what it had.
        #expect(models.status(tiny).received >= kept)
        try await waitUntil(seconds: 900) {
            if case .failed = models.status(tiny).phase { return true }
            return models.status(tiny).phase == .installed
        }
        print("SPEECH | \(models.status(tiny))")
        #expect(models.status(tiny).phase == .installed)
        let folder = models.folder(tiny)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("AudioEncoder.mlmodelc").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path))
    }

    @Test("Transcribes speech offline, with the speaker model loaded")
    func transcribe() async throws {
        if !models.isInstalled(tiny) {
            models.download(tiny)
            try await waitUntil(seconds: 900) { models.isInstalled(tiny) }
        }
        let hadSpeakers = models.isInstalled(SpeechModels.speakers)
        if !hadSpeakers {
            models.download(SpeechModels.speakers)
            try await waitUntil(seconds: 600) {
                if case .failed = models.status(SpeechModels.speakers).phase { return true }
                return models.isInstalled(SpeechModels.speakers)
            }
        }
        #expect(models.isInstalled(SpeechModels.speakers))

        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("speech-test.caf")
        try await speak([
            ("Hi Budi, did you book the table at Bakmi for Saturday?", "en-US"),
            ("Yes, I booked it for seven in the evening. Can you bring the cake?", "en-GB"),
            ("Sure, I will bring the birthday cake.", "en-US"),
        ], to: audio)

        let started = Date()
        let result = try await LocalSpeech.transcribe(audio, whisperFolder: models.folder(tiny),
                                                      speakersFolder: models.folder(SpeechModels.speakers))
        print("SPEECH | \(String(format: "%.1f", Date().timeIntervalSince(started)))s, \(result.speakers) speakers:\n\(result.text)")
        let text = result.text.lowercased()
        #expect(text.contains("table") || text.contains("cake"))

        // Leave this Mac as it was.
        models.delete(tiny)
        if !hadSpeakers { models.delete(SpeechModels.speakers) }
        try? FileManager.default.removeItem(at: audio)
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private struct TimeoutError: Error {}
}

/// Speaks each line with a system voice into one audio file: a conversation to transcribe.
private func speak(_ lines: [(text: String, language: String)], to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let sink = AudioSink(url: url)
    for line in lines {
        let utterance = AVSpeechUtterance(string: line.text)
        utterance.voice = AVSpeechSynthesisVoice(language: line.language)
        let synthesizer = AVSpeechSynthesizer()
        let once = Once()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            synthesizer.write(utterance) { buffer in
                // An empty buffer marks the end of the line.
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    once.run { done.resume() }
                    return
                }
                sink.write(pcm)
            }
        }
    }
    sink.close()
}

/// Collects the synthesizer's buffers into one file, converting later voices to the first one's format.
private final class AudioSink: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                    commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        }
        guard let file else { return }
        if buffer.format == file.processingFormat {
            try? file.write(from: buffer)
        } else if let converter = AVAudioConverter(from: buffer.format, to: file.processingFormat),
                  let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * file.processingFormat.sampleRate / buffer.format.sampleRate) + 1024) {
            var fed = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            try? file.write(from: out)
        }
    }

    func close() { file = nil }
}

/// Runs its block the first time only.
private final class Once: @unchecked Sendable {
    private var ran = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        let first = lock.withLock { defer { ran = true }; return !ran }
        if first { block() }
    }
}
