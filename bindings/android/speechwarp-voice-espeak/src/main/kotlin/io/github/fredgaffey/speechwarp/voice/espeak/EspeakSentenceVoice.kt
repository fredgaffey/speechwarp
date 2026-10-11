package io.github.fredgaffey.speechwarp.voice.espeak

import android.content.Context
import io.github.fredgaffey.speechwarp.voice.SentenceVoice

/**
 * eSpeak NG's formant voice in one language or accent, as a [SentenceVoice] for a live reader and a voice cache.
 * Quick enough to speak as it is heard, so nothing needs keeping.
 *
 * Every instance shares the one eSpeak (see [Espeak]), whose calls take turns. eSpeak NG is licensed under the
 * GPL-3.0-or-later; so is this library, and an app that uses it.
 */
class EspeakSentenceVoice private constructor(
    /** The voice, such as "en-gb". */
    val language: String,
    /** Speaking rate in words a minute. */
    val wordsPerMinute: Int,
    /** Pitch, 0 to 100. */
    val pitch: Int,
    context: Context?,
) : SentenceVoice {

    /**
     * A voice for [language], such as "en-us", "en-gb", "en-gb-x-rp" or "en-us+klatt" (see [Espeak.voices] and
     * [Espeak.variants]), at a rate and pitch, with eSpeak's data put in place from the app's assets first
     * ([Espeak.initialize]).
     *
     * @param context Any context of the app.
     * @param language The voice, as [Espeak.speak] takes it.
     * @param wordsPerMinute Speaking rate, 80 to 450.
     * @param pitch Pitch, 0 to 100.
     * @throws IllegalStateException eSpeak could not start.
     */
    @JvmOverloads
    constructor(
        context: Context,
        language: String = "en-us",
        wordsPerMinute: Int = Espeak.DEFAULT_WORDS_PER_MINUTE,
        pitch: Int = Espeak.DEFAULT_PITCH,
    ) : this(language, wordsPerMinute, pitch, context)

    /**
     * A voice for [language] when eSpeak's data is already in place: [Espeak.initialize] has been called, or
     * [Espeak.dataPath] set.
     *
     * @throws IllegalStateException eSpeak could not start (its data is missing).
     */
    @JvmOverloads
    constructor(
        language: String = "en-us",
        wordsPerMinute: Int = Espeak.DEFAULT_WORDS_PER_MINUTE,
        pitch: Int = Espeak.DEFAULT_PITCH,
    ) : this(language, wordsPerMinute, pitch, null)

    init {
        require(language.isNotBlank()) { "The language must not be blank." }
        if (context != null) Espeak.initialize(context)
    }

    /** Frames a second of what [speak] returns: eSpeak's 22,050. */
    override val sampleRate: Int = Espeak.sampleRate

    /**
     * "espeak:" and the language, such as "espeak:en-gb"; at a rate or pitch other than the defaults, these follow,
     * as in "espeak:en-gb/220/50", so that cached audio is never taken for another rate's.
     */
    override val id: String =
        if (wordsPerMinute == Espeak.DEFAULT_WORDS_PER_MINUTE && pitch == Espeak.DEFAULT_PITCH) "espeak:$language"
        else "espeak:$language/$wordsPerMinute/$pitch"

    /**
     * Speaks [sentence]: mono samples, -1 to 1, at [sampleRate]; empty for nothing to say.
     *
     * @throws IllegalArgumentException eSpeak has no voice [language].
     */
    override fun speak(sentence: String): FloatArray = Espeak.speak(sentence, language, wordsPerMinute, pitch)

    /** Nothing to release: eSpeak stays loaded for the life of the process. */
    override fun close() {}
}
