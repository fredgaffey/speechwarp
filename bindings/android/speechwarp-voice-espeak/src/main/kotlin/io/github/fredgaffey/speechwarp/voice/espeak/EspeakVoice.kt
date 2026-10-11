package io.github.fredgaffey.speechwarp.voice.espeak

/** Whom an eSpeak voice is meant to sound like. */
enum class EspeakGender {
    /** Not given. */
    UNKNOWN,

    /** A man. */
    MALE,

    /** A woman. */
    FEMALE,
}

/**
 * A voice in eSpeak's data: one language or accent.
 *
 * @property name eSpeak's name for it, such as "English (Great Britain)".
 * @property identifier Its file in the data, such as "gmw/en".
 * @property languages The languages it speaks, the most particular first, such as "en-gb-x-rp", "en-gb" and "en":
 * the first is what to give [Espeak.speak], [Espeak.phonemes] or [EspeakSentenceVoice].
 * @property gender Whom it is meant to sound like.
 */
data class EspeakVoice(
    val name: String,
    val identifier: String,
    val languages: List<String>,
    val gender: EspeakGender,
) {
    /** The language to ask for this voice by, such as "en-gb". */
    val language: String get() = languages.firstOrNull() ?: identifier

    internal companion object {
        /** One line of [EspeakNative.listVoices]: name, identifier, gender and languages, separated by tabs. */
        fun parse(line: String): EspeakVoice? {
            val fields = line.split('\t')
            if (fields.size < 4) return null
            val gender = when (fields[2]) {
                "1" -> EspeakGender.MALE
                "2" -> EspeakGender.FEMALE
                else -> EspeakGender.UNKNOWN
            }
            return EspeakVoice(fields[0], fields[1], fields[3].split(',').filter { it.isNotEmpty() }, gender)
        }
    }
}
