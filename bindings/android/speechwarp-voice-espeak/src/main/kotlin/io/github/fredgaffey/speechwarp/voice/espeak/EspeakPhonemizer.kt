package io.github.fredgaffey.speechwarp.voice.espeak

import android.content.Context
import io.github.fredgaffey.speechwarp.voice.Phonemizer

/**
 * eSpeak NG's text to phonemes (IPA), for a neural voice that needs phonemes, such as Kokoro
 * (speechwarp-voice-kokoro): `KokoroSentenceVoice(directory, "af_heart", EspeakPhonemizer(context))`.
 *
 * Thread-safe: it shares the one eSpeak (see [Espeak]), whose calls take turns. eSpeak NG is licensed under the
 * GPL-3.0-or-later; so is this library, and an app that uses it.
 */
class EspeakPhonemizer() : Phonemizer {
    /** A phonemizer that first puts eSpeak's data in place from the app's assets ([Espeak.initialize]). */
    constructor(context: Context) : this() {
        Espeak.initialize(context)
    }

    /**
     * eSpeak's IPA for [text] in [language] ("en-us", "en-gb"), clauses separated by a space. eSpeak's phonemes as
     * they are: any changes a model needs (Kokoro's, for one) are the model's.
     *
     * @throws IllegalArgumentException eSpeak has no voice [language].
     * @throws IllegalStateException eSpeak could not start (its data is missing).
     */
    override fun phonemize(text: String, language: String): String = Espeak.phonemes(text, language)
}
