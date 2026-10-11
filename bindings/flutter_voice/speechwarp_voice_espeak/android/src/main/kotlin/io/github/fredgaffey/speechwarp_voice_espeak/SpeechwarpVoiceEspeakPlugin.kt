package io.github.fredgaffey.speechwarp_voice_espeak

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.VoiceFactory
import io.github.fredgaffey.speechwarp.voice.espeak.Espeak
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakPhonemizer
import io.github.fredgaffey.speechwarp.voice.espeak.EspeakSentenceVoice

// eSpeak NG is licensed under the GPL-3.0-or-later, and so is this package.

/** The method channel "speechwarp_voice_espeak", for Dart's `Espeak`: eSpeak NG's version and phonemes. */
class SpeechwarpVoiceEspeakPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "speechwarp_voice_espeak")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // The first call copies eSpeak's data into the app's files folder: off the main thread.
        Thread {
            try {
                Espeak.initialize(context)
                val value: Any = when (call.method) {
                    "version" -> Espeak.version
                    "phonemes" -> Espeak.phonemes(
                        call.argument<String>("text") ?: "",
                        call.argument<String>("language") ?: "en-us",
                    )
                    else -> {
                        main.post { result.notImplemented() }
                        return@Thread
                    }
                }
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("espeak", e.message ?: e.toString(), null) }
            }
        }.start()
    }
}

/**
 * eSpeak NG for speechwarp_voice, which finds this class by name (see its Engines): makes "espeak:LANGUAGE" and
 * "espeak:LANGUAGE/RATE/PITCH" voices, lists them, and gives Kokoro its phonemizer. Not for use by apps.
 */
class EspeakProvider(private val context: Context) {
    fun factory(@Suppress("UNUSED_PARAMETER") options: Map<String, Any?>): VoiceFactory = VoiceFactory { id ->
        require(id.startsWith(PREFIX)) { "$id is not an eSpeak voice" }
        val parts = id.removePrefix(PREFIX).split('/')
        require(parts.size == 1 || parts.size == 3) { "$id is not an eSpeak voice's id" }
        if (parts.size == 3) {
            val rate = parts[1].toIntOrNull()
            val pitch = parts[2].toIntOrNull()
            require(rate != null && pitch != null) { "$id has no rate and pitch that can be read" }
            EspeakSentenceVoice(context, parts[0], rate, pitch)
        } else {
            EspeakSentenceVoice(context, parts[0])
        }
    }

    fun voices(@Suppress("UNUSED_PARAMETER") options: Map<String, Any?>): List<Map<String, Any?>> {
        Espeak.initialize(context)
        return Espeak.voices.map { voice ->
            mapOf(
                "id" to PREFIX + voice.language,
                "name" to voice.name,
                "language" to voice.language,
                "engine" to "espeak",
                "installed" to true,
                "keepsSpoken" to false,
                "details" to mapOf("identifier" to voice.identifier, "gender" to voice.gender.name.lowercase()),
            )
        }
    }

    fun phonemizer(): Phonemizer {
        Espeak.initialize(context)
        return EspeakPhonemizer()
    }

    private companion object {
        const val PREFIX = "espeak:"
    }
}
