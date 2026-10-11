package io.github.fredgaffey.speechwarp.reactnative.voice

import android.content.Context
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.SentenceVoice

/** A voice that can read, as listVoices reports it. */
data class VoiceInfo(
    val id: String,
    val name: String,
    val language: String,
    val engine: String,
    val installed: Boolean = true,
    val requiresNetwork: Boolean = false,
    val keepsSpoken: Boolean = false,
)

/**
 * An engine beyond Android's own voices: its voices' ids start with [prefix] ("espeak:", "kokoro:"). The packages
 * react-native-speechwarp-voice-espeak and -kokoro each have one, which [VoiceProviders] finds by name; an app can
 * [VoiceProviders.register] its own.
 */
interface VoiceProvider {
    val prefix: String

    /** Called off the main thread. */
    fun voices(context: Context): List<VoiceInfo>

    /** Called off the main thread (on the reader's thread for a voice change). */
    fun create(context: Context, id: String): SentenceVoice

    /** A phonemizer this engine offers to neural voices (eSpeak's), or null. */
    fun phonemizer(context: Context): Phonemizer? = null
}

/** The engines readers can make voices with, and the phonemizer neural voices use. */
object VoiceProviders {
    // The engine packages' providers, found by name so that this package does not depend on them (eSpeak is GPL).
    private val known = listOf(
        "io.github.fredgaffey.speechwarp.reactnative.voice.espeak.EspeakVoiceProvider",
        "io.github.fredgaffey.speechwarp.reactnative.voice.kokoro.KokoroVoiceProvider",
    )
    private val providers = mutableListOf<VoiceProvider>()
    private var loaded = false

    /** A phonemizer of the app's own for Kokoro, used before any engine's (react-native-speechwarp-voice-espeak's). */
    @Volatile
    @JvmStatic
    var phonemizer: Phonemizer? = null

    /** The phonemizer for neural voices: [phonemizer], or else an engine's; null if there is none. */
    @JvmStatic
    fun phonemizer(context: Context): Phonemizer? =
        phonemizer ?: all().firstNotNullOfOrNull { it.phonemizer(context) }

    /** Adds an engine; one for the same prefix is replaced. */
    @JvmStatic
    fun register(provider: VoiceProvider) = synchronized(this) {
        providers.removeAll { it.prefix == provider.prefix }
        providers += provider
    }

    @JvmStatic
    fun all(): List<VoiceProvider> = synchronized(this) {
        if (!loaded) {
            loaded = true
            for (name in known) {
                val provider = try {
                    Class.forName(name).getDeclaredConstructor().newInstance() as VoiceProvider
                } catch (_: ClassNotFoundException) {
                    continue // that package is not installed
                } catch (_: LinkageError) {
                    continue // installed without its native library
                }
                if (providers.none { it.prefix == provider.prefix }) providers += provider
            }
        }
        providers.toList()
    }

    /** The engine for a voice id, or null. */
    @JvmStatic
    fun find(id: String): VoiceProvider? = all().firstOrNull { id.startsWith(it.prefix) }
}
