package io.github.fredgaffey.speechwarp_voice_kokoro

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.VoiceFactory
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroFile
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroModels
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroOptions
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroSentenceVoice
import java.io.File

/** The method channel "speechwarp_voice_kokoro": Kokoro's catalogue of model files, for Dart's `Kokoro`. */
class SpeechwarpVoiceKokoroPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "speechwarp_voice_kokoro")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "catalogue" -> result.success(
                    mapOf(
                        "repository" to KokoroModels.REPOSITORY,
                        "revision" to KokoroModels.REVISION,
                        "defaultModelFile" to KokoroModels.DEFAULT_MODEL_FILE,
                        "defaultVoice" to KokoroModels.DEFAULT_VOICE,
                        "tokenizer" to KokoroModels.tokenizer.toMap(),
                        "models" to KokoroModels.models.map {
                            mapOf("id" to it.id, "name" to it.name, "description" to it.description, "file" to it.file.toMap())
                        },
                        "voices" to KokoroModels.voices.map {
                            mapOf("name" to it.name, "language" to it.language, "isFemale" to it.isFemale, "file" to it.file.toMap())
                        },
                    ),
                )
                "missingFiles" -> result.success(
                    KokoroModels.missingFiles(
                        File(call.argument<String>("directory") ?: throw IllegalArgumentException("No directory")),
                        call.argument<String>("voice") ?: KokoroModels.DEFAULT_VOICE,
                        call.argument<String>("modelFile") ?: KokoroModels.DEFAULT_MODEL_FILE,
                    ).map { it.toMap() },
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("kokoro", e.message ?: e.toString(), null)
        }
    }
}

internal fun KokoroFile.toMap() = mapOf("relativePath" to relativePath, "sizeBytes" to sizeBytes, "url" to url, "sha256" to sha256)

/**
 * Kokoro for speechwarp_voice, which finds this class by name (see its Engines): makes "kokoro:NAME" and
 * "kokoro:NAME/PACE" voices and lists them. Not for use by apps.
 */
class KokoroProvider(@Suppress("unused") private val context: Context) {
    /** Options: "kokoroDirectory" (required), "kokoroModelFile", "phonemizer" (required). */
    fun factory(options: Map<String, Any?>): VoiceFactory {
        val directory = File(options["kokoroDirectory"] as String? ?: throw IllegalStateException("No Kokoro model directory"))
        val phonemizer = options["phonemizer"] as Phonemizer? ?: throw IllegalStateException("No phonemizer for Kokoro")
        val kokoroOptions = (options["kokoroModelFile"] as String?)?.let { KokoroOptions(modelFile = it) } ?: KokoroOptions()
        return VoiceFactory { id ->
            require(id.startsWith(PREFIX)) { "$id is not a Kokoro voice" }
            val parts = id.removePrefix(PREFIX).split('/')
            val speed = if (parts.size > 1) parts[1].toFloatOrNull() ?: throw IllegalArgumentException("$id has no pace that can be read") else 1f
            KokoroSentenceVoice(directory, parts[0], phonemizer, kokoroOptions, speed)
        }
    }

    /** Every voice in the catalogue, installed when its files are in "kokoroDirectory". */
    fun voices(options: Map<String, Any?>): List<Map<String, Any?>> {
        val directory = (options["kokoroDirectory"] as String?)?.let(::File)
        val modelFile = options["kokoroModelFile"] as String? ?: KokoroModels.DEFAULT_MODEL_FILE
        return KokoroModels.voices.map { voice ->
            mapOf(
                "id" to PREFIX + voice.name,
                "name" to voice.name,
                "language" to voice.language,
                "engine" to "kokoro",
                "installed" to (directory != null && KokoroModels.isInstalled(directory, voice.name, modelFile)),
                "keepsSpoken" to true,
                "details" to mapOf("isFemale" to voice.isFemale),
            )
        }
    }

    private companion object {
        const val PREFIX = "kokoro:"
    }
}
