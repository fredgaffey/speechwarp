package io.github.fredgaffey.speechwarp.reactnative.voice.espeak

import android.content.Context
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceInfo
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceProvider
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.SentenceVoice
import io.github.fredgaffey.speechwarp.voice.espeak.Espeak
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakPhonemizer
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakSentenceVoice

/**
 * eSpeak NG's voices ("espeak:en-gb", or "espeak:en-gb/220/50" at a rate and pitch) and its phonemizer, for
 * react-native-speechwarp-voice, which finds this class by name.
 */
class EspeakVoiceProvider : VoiceProvider {
    override val prefix = PREFIX

    override fun voices(context: Context): List<VoiceInfo> {
        Espeak.initialize(context)
        return Espeak.voices.map { VoiceInfo(id = PREFIX + it.language, name = it.name, language = it.language, engine = "espeak") }
    }

    override fun create(context: Context, id: String): SentenceVoice {
        val parts = id.removePrefix(PREFIX).split('/')
        require(parts[0].isNotEmpty() && (parts.size == 1 || parts.size == 3)) {
            "$id is not an eSpeak voice's id: \"espeak:LANGUAGE\" or \"espeak:LANGUAGE/WORDS-A-MINUTE/PITCH\""
        }
        if (parts.size == 1) return EspeakSentenceVoice(context, parts[0])
        val wordsPerMinute = requireNotNull(parts[1].toIntOrNull()) { "$id: the rate is not a whole number" }
        val pitch = requireNotNull(parts[2].toIntOrNull()) { "$id: the pitch is not a whole number" }
        return EspeakSentenceVoice(context, parts[0], wordsPerMinute, pitch)
    }

    override fun phonemizer(context: Context): Phonemizer = EspeakPhonemizer(context)

    companion object {
        const val PREFIX = "espeak:"
    }
}
