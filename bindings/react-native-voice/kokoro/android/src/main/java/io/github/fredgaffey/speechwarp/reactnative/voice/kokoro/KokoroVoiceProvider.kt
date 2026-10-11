package io.github.fredgaffey.speechwarp.reactnative.voice.kokoro

import android.content.Context
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceInfo
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceProvider
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceProviders
import io.github.fredgaffey.speechwarp.voice.SentenceVoice
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroModels
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroOptions
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroSentenceVoice
import java.io.File

/** Where Kokoro's files are and which model it loads; set from JavaScript. */
object KokoroSettings {
    @Volatile private var chosen: File? = null
    @Volatile var modelFile: String = KokoroModels.DEFAULT_MODEL_FILE

    fun directory(context: Context): File = chosen ?: File(context.applicationContext.filesDir, "speechwarp-kokoro")

    fun setDirectory(directory: File) {
        chosen = directory
    }
}

/**
 * Kokoro's voices ("kokoro:af_heart", or "kokoro:af_heart/1.2" at another pace) for react-native-speechwarp-voice,
 * which finds this class by name. The phonemizer comes from react-native-speechwarp-voice-espeak or the app.
 */
class KokoroVoiceProvider : VoiceProvider {
    override val prefix = PREFIX

    override fun voices(context: Context): List<VoiceInfo> {
        val directory = KokoroSettings.directory(context)
        return KokoroModels.voices.map {
            VoiceInfo(
                id = PREFIX + it.name,
                name = it.name,
                language = it.language,
                engine = "kokoro",
                installed = KokoroModels.isInstalled(directory, it.name, KokoroSettings.modelFile),
                keepsSpoken = true,
            )
        }
    }

    override fun create(context: Context, id: String): SentenceVoice {
        val parts = id.removePrefix(PREFIX).split('/')
        require(parts.size <= 2 && parts[0].isNotEmpty()) { "$id is not a Kokoro voice's id: \"kokoro:NAME\" or \"kokoro:NAME/PACE\"" }
        val speed = if (parts.size == 2) requireNotNull(parts[1].toFloatOrNull()) { "$id: the pace is not a number" } else 1f
        val phonemizer = VoiceProviders.phonemizer(context) ?: throw IllegalStateException(
            "Kokoro needs a phonemizer: add react-native-speechwarp-voice-espeak (GPL-3.0-or-later), or set " +
                "VoiceProviders.phonemizer to one of your own"
        )
        val directory = KokoroSettings.directory(context)
        val missing = KokoroModels.missingFiles(directory, parts[0], KokoroSettings.modelFile)
        check(missing.isEmpty()) {
            "Kokoro's files are not all in $directory: missing ${missing.joinToString { it.relativePath }}"
        }
        return KokoroSentenceVoice(directory, parts[0], phonemizer, KokoroOptions(modelFile = KokoroSettings.modelFile), speed)
    }

    companion object {
        const val PREFIX = "kokoro:"
    }
}
