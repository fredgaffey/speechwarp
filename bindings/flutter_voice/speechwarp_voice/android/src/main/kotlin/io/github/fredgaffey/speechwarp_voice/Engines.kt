package io.github.fredgaffey.speechwarp_voice

import android.content.Context
import io.github.fredgaffey.speechwarp.voice.AndroidSentenceVoice
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.VoiceFactory
import java.lang.reflect.InvocationTargetException

/** A voice id whose engine is not in the app (or no engine has that prefix). */
class EngineMissingException(message: String) : IllegalArgumentException(message)

/** Kokoro cannot be made: no model directory, or no phonemizer. */
class KokoroSetupException(message: String) : IllegalStateException(message)

/**
 * The voice engines: Android's own (always), and Kokoro and eSpeak NG when their Flutter packages
 * (speechwarp_voice_kokoro, speechwarp_voice_espeak) are in the app.
 *
 * Each of those packages carries the engine's library and one "provider" class, found here by name, so that this
 * package neither depends on them nor links them (eSpeak NG is GPL-3.0-or-later; Kokoro brings ONNX Runtime). A
 * provider has a public constructor taking a [Context] and these methods, which take the options map built by the
 * plugin ("kokoroDirectory", "kokoroModelFile", "phonemizer"):
 *
 * - `factory(options: Map<String, Any?>): VoiceFactory` makes voices for its ids;
 * - `voices(options: Map<String, Any?>): List<Map<String, Any?>>` lists them as Dart's VoiceInfo.fromMap reads them;
 * - eSpeak's also has `phonemizer(): Phonemizer`, Kokoro's phonemizer unless the app sets
 *   [SpeechwarpVoicePlugin.phonemizer].
 */
internal class Engines(private val context: Context) {
    private class Provider(val instance: Any) {
        fun factory(options: Map<String, Any?>): VoiceFactory = call("factory", options) as VoiceFactory

        @Suppress("UNCHECKED_CAST")
        fun voices(options: Map<String, Any?>): List<Map<String, Any?>> = call("voices", options) as List<Map<String, Any?>>

        fun phonemizer(): Phonemizer = unwrap { instance.javaClass.getMethod("phonemizer").invoke(instance) } as Phonemizer

        private fun call(name: String, options: Map<String, Any?>): Any? =
            unwrap { instance.javaClass.getMethod(name, Map::class.java).invoke(instance, options) }

        private fun unwrap(body: () -> Any?): Any? = try {
            body()
        } catch (e: InvocationTargetException) {
            throw e.targetException
        }
    }

    private val kokoro: Provider? by lazy { load("io.github.fredgaffey.speechwarp_voice_kokoro.KokoroProvider") }
    private val espeak: Provider? by lazy { load("io.github.fredgaffey.speechwarp_voice_espeak.EspeakProvider") }

    private fun load(name: String): Provider? = try {
        Provider(Class.forName(name).getConstructor(Context::class.java).newInstance(context))
    } catch (e: ClassNotFoundException) {
        null
    }

    /** Makes voices by id, on the reader's thread (or on the plugin's background thread for the first). */
    fun factory(options: Map<String, Any?>): VoiceFactory {
        // Kokoro's phonemizer: the app's own, else eSpeak's if it is there. Asked for only when a Kokoro voice is.
        val phonemizer by lazy { options["phonemizer"] as Phonemizer? ?: espeak?.phonemizer() }
        val kokoroFactory by lazy { kokoro?.factory(options + ("phonemizer" to phonemizer)) }
        val espeakFactory by lazy { espeak?.factory(options) }
        return VoiceFactory { id ->
            when {
                id.startsWith(AndroidSentenceVoice.ID_PREFIX) -> AndroidSentenceVoice.fromId(context, id)
                id.startsWith("kokoro:") -> {
                    if (kokoro == null) {
                        throw EngineMissingException("$id is a Kokoro voice: add the speechwarp_voice_kokoro package to the app")
                    }
                    if (options["kokoroDirectory"] == null) {
                        throw KokoroSetupException("Kokoro needs ReaderOptions.kokoroDirectory, the folder of its model files")
                    }
                    if (phonemizer == null) {
                        throw KokoroSetupException(
                            "Kokoro needs a phonemizer: add speechwarp_voice_espeak (GPL-3.0-or-later), or set " +
                                "SpeechwarpVoicePlugin.phonemizer from the app's Kotlin",
                        )
                    }
                    kokoroFactory!!.create(id)
                }
                id.startsWith("espeak:") -> (espeakFactory
                    ?: throw EngineMissingException("$id is an eSpeak NG voice: add the speechwarp_voice_espeak package to the app"))
                    .create(id)
                else -> throw EngineMissingException("No engine for the voice $id")
            }
        }
    }

    /** Every voice: Android's, then Kokoro's and eSpeak's when they are there. Blocks; never on the main thread. */
    fun voices(options: Map<String, Any?>): List<Map<String, Any?>> {
        val list = ArrayList<Map<String, Any?>>()
        for (voice in AndroidSentenceVoice.voices(context)) {
            list += mapOf(
                "id" to voice.id,
                "name" to voice.name,
                "language" to voice.locale.toLanguageTag(),
                "engine" to "android",
                "installed" to voice.isInstalled,
                "keepsSpoken" to false,
                "details" to mapOf(
                    "quality" to voice.quality,
                    "latency" to voice.latency,
                    "requiresNetwork" to voice.requiresNetwork,
                ),
            )
        }
        kokoro?.let { list += it.voices(options) }
        espeak?.let { list += it.voices(options) }
        return list
    }
}
