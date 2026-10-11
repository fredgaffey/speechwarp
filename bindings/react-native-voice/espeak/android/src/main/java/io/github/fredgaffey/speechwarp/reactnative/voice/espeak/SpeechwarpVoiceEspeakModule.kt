package io.github.fredgaffey.speechwarp.reactnative.voice.espeak

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import io.github.fredgaffey.speechwarp.voice.espeak.Espeak
import java.util.concurrent.Executors

class SpeechwarpVoiceEspeakModule(reactContext: ReactApplicationContext) : NativeSpeechwarpVoiceEspeakSpec(reactContext) {
    private val context = reactContext.applicationContext
    // The first call copies eSpeak's data into place, so none of this runs on the JavaScript thread.
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "speechwarp-voice-espeak").apply { isDaemon = true } }

    override fun version(): String = Espeak.version

    override fun variants(promise: Promise) = worker.execute {
        try {
            Espeak.initialize(context)
            promise.resolve(Arguments.fromList(Espeak.variants))
        } catch (e: Throwable) {
            promise.reject("speechwarp_espeak", e.message ?: e.toString(), e)
        }
    }

    override fun phonemize(text: String, language: String, promise: Promise) = worker.execute {
        try {
            Espeak.initialize(context)
            promise.resolve(Espeak.phonemes(text, language))
        } catch (e: Throwable) {
            promise.reject("speechwarp_espeak", e.message ?: e.toString(), e)
        }
    }

    override fun invalidate() {
        worker.shutdown()
        super.invalidate()
    }

    companion object {
        const val NAME = NativeSpeechwarpVoiceEspeakSpec.NAME
    }
}
