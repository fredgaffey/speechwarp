package io.github.fredgaffey.speechwarp.voice

// The engine-independent face of text-to-speech. An engine speaks one sentence at a time; the live reader
// (VoicedText) and the cache (VoiceCache) work with any engine. Engines: Android's own voices (this module),
// Kokoro (speechwarp-voice-kokoro) and eSpeak NG (speechwarp-voice-espeak, GPL-3).

/** An engine that speaks one sentence at a time, at its own sample rate. Called from one background thread at a time. */
interface SentenceVoice : AutoCloseable {
    /** Stable across runs: "android:<voice name>", "kokoro:af_heart", "espeak:en-gb". Cached audio is kept per id. */
    val id: String
    /** Frames a second of what speak returns. Mono. */
    val sampleRate: Int
    /** Mono samples, -1 to 1; empty for nothing to say. */
    fun speak(sentence: String): FloatArray
    /** Slower than listening: worth keeping on disk and speaking far ahead. */
    val keepsSpoken: Boolean get() = false
    override fun close() {}
}

/** Text to IPA for a neural voice such as Kokoro. */
interface Phonemizer { fun phonemize(text: String, language: String): String }
