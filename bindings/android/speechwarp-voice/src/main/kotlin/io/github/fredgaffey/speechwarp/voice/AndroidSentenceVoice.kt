package io.github.fredgaffey.speechwarp.voice

import android.content.Context
import android.os.Bundle
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * A voice of Android's text-to-speech service, as described by the engine.
 *
 * @property name the engine's name for it, such as "en-us-x-iol-local"
 * @property locale its language and region
 * @property quality [Voice.QUALITY_VERY_LOW] (100) to [Voice.QUALITY_VERY_HIGH] (500)
 * @property latency [Voice.LATENCY_VERY_LOW] (100) to [Voice.LATENCY_VERY_HIGH] (500)
 * @property requiresNetwork it speaks only with a network connection
 * @property isInstalled its data is on the device (an engine may list voices it has yet to download)
 */
data class AndroidVoice(
    val name: String,
    val locale: Locale,
    val quality: Int,
    val latency: Int,
    val requiresNetwork: Boolean,
    val isInstalled: Boolean,
) {
    /** The [SentenceVoice.id] of this voice at the normal rate and pitch: "android:" and its name. */
    val id: String get() = AndroidSentenceVoice.ID_PREFIX + name

    internal companion object {
        fun from(voice: Voice) = AndroidVoice(
            voice.name,
            voice.locale,
            voice.quality,
            voice.latency,
            voice.isNetworkConnectionRequired,
            TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in voice.features.orEmpty(),
        )
    }
}

/**
 * One of Android's text-to-speech voices as a [SentenceVoice], for [VoicedText] and anything else that works with any
 * engine.
 *
 * ```
 * // off the main thread:
 * AndroidSentenceVoice.open(context, "en-us-x-iol-local").use { voice ->
 *     val samples = voice.speak("Hello there.")   // mono, voice.sampleRate
 * }
 * ```
 *
 * Android speaks to a file only ([TextToSpeech.synthesizeToFile]): [speak] has the engine write a WAV file into the
 * app's cache directory, waits for it, reads it and deletes it. The engine starts asynchronously and reports to the
 * main thread, so **[speak] and [open] must never be called on the main thread**: they throw
 * [IllegalStateException] there rather than wait for something that cannot arrive. [VoicedText] calls [speak] on its
 * own thread. The constructor never waits and may be called on any thread.
 *
 * Quick: far faster than listening, so nothing needs keeping on disk ([keepsSpoken] is false).
 *
 * @param context any context; its application context is kept
 * @param voiceName the engine's name for the voice (see [voices]); null for the engine's default voice
 * @param rate the engine's speech rate, 1 normal, 2 twice as fast
 * @param pitch the engine's pitch, 1 normal
 * @param engine the package of the engine, such as "com.google.android.tts"; null for the user's chosen engine
 * @param sampleRate the rate [speak] returns, whatever the engine writes (it is converted). The engine's own rate
 * shows only once it has spoken, which is what [open] waits for; this constructor cannot, so it takes a rate.
 */
class AndroidSentenceVoice @JvmOverloads constructor(
    context: Context,
    voiceName: String? = null,
    /** The engine's speech rate: 1 normal. */
    val rate: Float = 1f,
    /** The engine's pitch: 1 normal. */
    val pitch: Float = 1f,
    /** The package of the engine, or null for the user's chosen one. */
    val engine: String? = null,
    sampleRate: Int = DEFAULT_SAMPLE_RATE,
) : SentenceVoice {
    private val tts: TextToSpeech
    private val started = CountDownLatch(1)
    @Volatile private var startStatus = TextToSpeech.ERROR
    private val folder = File(context.applicationContext.cacheDir, "speechwarp-voice-tts")
    private val pending = ConcurrentHashMap<String, Utterance>()
    private val setUp = Object()
    private var ready = false
    @Volatile private var closed = false

    private class Utterance {
        val done = CountDownLatch(1)
        @Volatile var error: Int? = null
    }

    init {
        require(rate > 0) { "rate must be more than 0" }
        require(pitch > 0) { "pitch must be more than 0" }
        require(sampleRate > 0) { "sampleRate must be more than 0" }
        tts = TextToSpeech(context.applicationContext, { status ->
            startStatus = status
            started.countDown()
        }, engine)
    }

    /** The engine's name for the voice; null for the engine's default until [open] resolves it. */
    var voiceName: String? = voiceName
        private set

    /**
     * "android:" and the voice's name, such as "android:en-us-x-iol-local" ("android:default" for the engine's default
     * voice when made without [open]); at a rate or pitch other than 1, these follow, as in
     * "android:en-us-x-iol-local/1.5/1", so that cached audio is never taken for another rate's.
     */
    override var id: String = idFor(voiceName, rate, pitch)
        private set

    /** The rate of what [speak] returns. */
    override var sampleRate: Int = sampleRate
        private set

    /** How long [speak] and [open] wait for the engine to start. Default 15 s. */
    @Volatile var startTimeoutMillis: Long = 15_000

    /** How long [speak] waits for the engine to speak a sentence before giving up. Default one minute. */
    @Volatile var timeoutMillis: Long = 60_000

    /**
     * Speaks [sentence] and waits for it; mono samples at [sampleRate]. Never call it on the main thread.
     *
     * @throws IllegalStateException on the main thread; when the engine did not start, has no such voice, or failed
     * @throws TimeoutException when the engine did not start or speak in time
     */
    override fun speak(sentence: String): FloatArray {
        if (sentence.isBlank()) return FloatArray(0)
        start()
        val limit = maxOf(1, TextToSpeech.getMaxSpeechInputLength())
        val parts = if (sentence.length <= limit) listOf(sentence) else sentence.chunked(limit)
        var result = FloatArray(0)
        for (part in parts) {
            val pcm = synthesize(part)
            val samples = AudioResampling.linear(pcm.samples, pcm.sampleRate, sampleRate)
            result = if (result.isEmpty()) samples else result + samples
        }
        return result
    }

    /** The voices the engine offers. Never call it on the main thread. */
    fun voices(): List<AndroidVoice> {
        start()
        return tts.voices.orEmpty().map(AndroidVoice::from).sortedBy { it.name }
    }

    /** Waits for the engine to start (the first time) and sets the voice, rate and pitch. */
    private fun start() {
        checkNotMainThread()
        check(!closed) { "The voice is closed" }
        synchronized(setUp) {
            if (ready) return
            if (!started.await(startTimeoutMillis, TimeUnit.MILLISECONDS)) {
                throw TimeoutException("Android's text-to-speech did not start within ${startTimeoutMillis / 1000} s")
            }
            check(startStatus == TextToSpeech.SUCCESS) { "Android's text-to-speech could not start (engine ${engine ?: "default"})" }
            val name = voiceName
            if (name != null) {
                val voice = tts.voices.orEmpty().firstOrNull { it.name == name }
                    ?: throw IllegalStateException("Android's text-to-speech has no voice $name")
                check(tts.setVoice(voice) == TextToSpeech.SUCCESS) { "Android's text-to-speech could not use the voice $name" }
            }
            tts.setSpeechRate(rate)
            tts.setPitch(pitch)
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String) {}
                override fun onDone(utteranceId: String) {
                    pending[utteranceId]?.done?.countDown()
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String) = onError(utteranceId, TextToSpeech.ERROR)

                override fun onError(utteranceId: String, errorCode: Int) {
                    pending[utteranceId]?.let {
                        it.error = errorCode
                        it.done.countDown()
                    }
                }

                override fun onStop(utteranceId: String, interrupted: Boolean) {
                    pending[utteranceId]?.let {
                        it.error = TextToSpeech.STOPPED
                        it.done.countDown()
                    }
                }
            })
            ready = true
        }
    }

    private fun synthesize(text: String): Pcm {
        if (!folder.isDirectory) folder.mkdirs()
        val id = UUID.randomUUID().toString()
        val file = File(folder, "$id.wav")
        val utterance = Utterance()
        pending[id] = utterance
        try {
            val queued = tts.synthesizeToFile(text, Bundle(), file, id)
            check(queued == TextToSpeech.SUCCESS) { "Android's text-to-speech would not take the text" }
            if (!utterance.done.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
                tts.stop()
                throw TimeoutException("Android's text-to-speech did not finish speaking within ${timeoutMillis / 1000} s")
            }
            utterance.error?.let { throw IllegalStateException("Android's text-to-speech failed (${errorName(it)})") }
            if (!file.isFile || file.length() == 0L) return Pcm(FloatArray(0), sampleRate)
            return Wav.read(file.readBytes())
        } finally {
            pending.remove(id)
            file.delete()
        }
    }

    /** Finds the engine's own sample rate by speaking a word, and returns it. */
    private fun measureSampleRate(): Int {
        start()
        return synthesize("Hello.").sampleRate.takeIf { it > 0 } ?: sampleRate
    }

    /** Releases the engine. */
    override fun close() {
        if (closed) return
        closed = true
        try {
            tts.stop()
        } catch (_: Exception) {
        }
        tts.shutdown()
    }

    companion object {
        /** The prefix of every [id]: "android:". */
        const val ID_PREFIX = "android:"

        /** What [AndroidSentenceVoice]'s constructor assumes the rate to be when not told: 24,000. */
        const val DEFAULT_SAMPLE_RATE = 24000

        /**
         * A voice that is ready to speak: waits for the engine to start, checks the voice is there (null: the engine's
         * default, whose name it then takes), and measures the engine's sample rate, which becomes [sampleRate].
         * Never call it on the main thread.
         *
         * @throws IllegalStateException on the main thread, or when the engine did not start or has no such voice
         * @throws TimeoutException when the engine did not start in time
         */
        @JvmStatic
        @JvmOverloads
        fun open(
            context: Context,
            voiceName: String? = null,
            rate: Float = 1f,
            pitch: Float = 1f,
            engine: String? = null,
        ): AndroidSentenceVoice {
            checkNotMainThread()
            val voice = AndroidSentenceVoice(context, voiceName, rate, pitch, engine)
            try {
                voice.start()
                if (voiceName == null) {
                    voice.tts.voice?.name?.let {
                        voice.voiceName = it
                        voice.id = idFor(it, rate, pitch)
                    }
                }
                voice.sampleRate = voice.measureSampleRate()
                return voice
            } catch (e: Exception) {
                voice.close()
                throw e
            }
        }

        /**
         * The voice with this [id] ("android:NAME", or "android:NAME/RATE/PITCH"), as [open] makes it: for a
         * [VoiceFactory]. Never call it on the main thread.
         *
         * @throws IllegalArgumentException when the id is not an Android voice's
         */
        @JvmStatic
        @JvmOverloads
        fun fromId(context: Context, id: String, engine: String? = null): AndroidSentenceVoice {
            require(id.startsWith(ID_PREFIX)) { "$id is not an Android voice's id (they start \"$ID_PREFIX\")" }
            val parts = id.substring(ID_PREFIX.length).split('/')
            require(parts.size == 1 || parts.size == 3) { "$id is not an Android voice's id" }
            val name = parts[0].takeUnless { it.isEmpty() || it == DEFAULT_NAME }
            val rate = if (parts.size == 3) parts[1].toFloatOrNull() else 1f
            val pitch = if (parts.size == 3) parts[2].toFloatOrNull() else 1f
            require(rate != null && pitch != null) { "$id has no rate and pitch that can be read" }
            return open(context, name, rate, pitch, engine)
        }

        /**
         * The voices the engine ([engine], or the user's chosen one) offers, sorted by name. Starts an engine to ask
         * it, so never call it on the main thread.
         *
         * @throws IllegalStateException on the main thread, or when the engine did not start
         * @throws TimeoutException when the engine did not start in time
         */
        @JvmStatic
        @JvmOverloads
        fun voices(context: Context, engine: String? = null): List<AndroidVoice> {
            checkNotMainThread()
            return AndroidSentenceVoice(context, engine = engine).use { it.voices() }
        }

        /** The text-to-speech engines installed, by package name. Never call it on the main thread. */
        @JvmStatic
        fun engines(context: Context): List<String> {
            checkNotMainThread()
            return AndroidSentenceVoice(context).use { voice ->
                voice.start()
                voice.tts.engines.map { it.name }
            }
        }

        private const val DEFAULT_NAME = "default"

        internal fun idFor(voiceName: String?, rate: Float, pitch: Float): String {
            val name = ID_PREFIX + (voiceName ?: DEFAULT_NAME)
            return if (rate == 1f && pitch == 1f) name else "$name/${number(rate)}/${number(pitch)}"
        }

        private fun number(value: Float): String =
            if (value == value.toInt().toFloat()) value.toInt().toString() else value.toString()

        private fun errorName(code: Int): String = when (code) {
            TextToSpeech.ERROR_SYNTHESIS -> "synthesis error"
            TextToSpeech.ERROR_SERVICE -> "service error"
            TextToSpeech.ERROR_OUTPUT -> "output error"
            TextToSpeech.ERROR_NETWORK -> "network error"
            TextToSpeech.ERROR_NETWORK_TIMEOUT -> "network timeout"
            TextToSpeech.ERROR_INVALID_REQUEST -> "invalid request"
            TextToSpeech.ERROR_NOT_INSTALLED_YET -> "voice data not installed yet"
            TextToSpeech.STOPPED -> "stopped"
            else -> "error $code"
        }

        private fun checkNotMainThread() {
            check(Looper.myLooper() != Looper.getMainLooper()) {
                "Android's text-to-speech reports to the main thread: call this on another thread"
            }
        }
    }
}
