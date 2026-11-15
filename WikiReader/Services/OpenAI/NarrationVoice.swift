import Foundation

/// The voice an article is read in: the model that speaks, the voice's name and the style it is asked to read in.
/// All three are part of every piece's cache name (`SpeechAudioCache.key`), so audio in one voice never passes for
/// another's.
///
/// This app's own voices are OpenAI's, asked for in its one style (`init(_:)`). English Reader narrates in whatever
/// voices it has (docs/site-api-for-ios.md §13): OpenAI's, Google's (2026-11-15), or a speaker's own recording. Its
/// audio is named the same way, from the model, voice and style it lists, so the files it sends are found by name.
nonisolated struct NarrationVoice: Codable, Hashable, Sendable {
    var model: String
    var voice: String
    var instructions: String

    init(model: String, voice: String, instructions: String) {
        self.model = model
        self.voice = voice
        self.instructions = instructions
    }

    /// One of this app's OpenAI voices ("alloy"), asked for the way this app asks; or a recording on English Reader
    /// ("rec-…"), named its way: its model and no instructions.
    init(_ voice: String) {
        if OpenAISpeechEngine.isRecording(voice) {
            self.init(model: OpenAISpeechEngine.recordingModel, voice: voice, instructions: "")
        } else {
            self.init(model: OpenAISpeechEngine.model, voice: voice, instructions: OpenAISpeechEngine.instructions)
        }
    }

    /// The request that reads `text` in this voice.
    func request(for text: String) -> OpenAISpeechRequest {
        OpenAISpeechRequest(model: model, voice: voice, input: text, instructions: instructions)
    }

    /// A speaker's own recording on English Reader.
    var isRecording: Bool { model == OpenAISpeechEngine.recordingModel }

    /// Only English Reader has this voice's audio: a recording, or a voice OpenAI doesn't make (Google's). It is never
    /// generated here, and never looked for on Google Drive or put there.
    var isSiteOnly: Bool { model != OpenAISpeechEngine.model }

    /// "Alloy", "Kore"; "Original Recording" for a speaker's own recording.
    var displayName: String { OpenAISpeechEngine.displayName(of: voice) }
}
