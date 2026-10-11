package io.github.fredgaffey.speechwarp.reactnative.voice.kokoro

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import io.github.fredgaffey.speechwarp.reactnative.voice.VoiceProviders
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroFile
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroModels
import java.io.File

class SpeechwarpVoiceKokoroModule(reactContext: ReactApplicationContext) : NativeSpeechwarpVoiceKokoroSpec(reactContext) {
    private val context = reactContext.applicationContext

    override fun catalogue(): WritableMap = Arguments.createMap().apply {
        putString("repository", KokoroModels.REPOSITORY)
        putString("revision", KokoroModels.REVISION)
        putString("defaultModelFile", KokoroModels.DEFAULT_MODEL_FILE)
        putString("defaultVoice", KokoroModels.DEFAULT_VOICE)
        putMap("tokenizer", file(KokoroModels.tokenizer))
        putArray("models", Arguments.createArray().apply {
            for (model in KokoroModels.models) {
                pushMap(Arguments.createMap().apply {
                    putString("id", model.id)
                    putString("name", model.name)
                    putString("description", model.description)
                    putMap("file", file(model.file))
                })
            }
        })
        putArray("voices", Arguments.createArray().apply {
            for (voice in KokoroModels.voices) {
                pushMap(Arguments.createMap().apply {
                    putString("name", voice.name)
                    putString("language", voice.language)
                    putBoolean("female", voice.isFemale)
                    putMap("file", file(voice.file))
                })
            }
        })
    }

    override fun directory(): String = KokoroSettings.directory(context).path

    override fun setDirectory(path: String): String {
        KokoroSettings.setDirectory(File(path))
        return path
    }

    override fun modelFile(): String = KokoroSettings.modelFile

    override fun setModelFile(fileName: String): String {
        require(KokoroModels.findModel(fileName) != null) { "$fileName is not one of Kokoro's models" }
        KokoroSettings.modelFile = fileName
        return fileName
    }

    override fun missingFiles(voice: String): WritableArray = Arguments.createArray().apply {
        for (missing in KokoroModels.missingFiles(KokoroSettings.directory(context), voice, KokoroSettings.modelFile)) {
            pushMap(file(missing))
        }
    }

    override fun isInstalled(voice: String): Boolean =
        KokoroModels.isInstalled(KokoroSettings.directory(context), voice, KokoroSettings.modelFile)

    override fun hasPhonemizer(): Boolean = VoiceProviders.phonemizer(context) != null

    override fun engineIncluded(): Boolean = true

    private fun file(file: KokoroFile): WritableMap = Arguments.createMap().apply {
        putString("path", file.relativePath)
        putDouble("size", file.sizeBytes.toDouble())
        putString("url", file.url)
        putString("sha256", file.sha256)
    }

    companion object {
        const val NAME = NativeSpeechwarpVoiceKokoroSpec.NAME
    }
}
