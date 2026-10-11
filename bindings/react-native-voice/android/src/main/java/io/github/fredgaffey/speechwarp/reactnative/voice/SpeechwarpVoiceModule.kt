package io.github.fredgaffey.speechwarp.reactnative.voice

import android.content.Context
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import io.github.fredgaffey.speechwarp.voice.AndroidSentenceVoice
import io.github.fredgaffey.speechwarp.voice.VoiceCache
import io.github.fredgaffey.speechwarp.voice.VoiceFactory
import io.github.fredgaffey.speechwarp.voice.VoicedText
import io.github.fredgaffey.speechwarp.voice.VoicedTextOptions
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * The React Native face of speechwarp-voice: readers made by id, played natively, reporting where they are.
 *
 * Making a voice and listing voices start Android's text-to-speech engine, which must not happen on the main thread,
 * so those run on a thread of this module's own.
 */
class SpeechwarpVoiceModule(reactContext: ReactApplicationContext) : NativeSpeechwarpVoiceSpec(reactContext) {
    private val context: Context = reactContext.applicationContext
    private val players = ConcurrentHashMap<Int, ReaderPlayer>()
    private val aheadToDiskFlags = ConcurrentHashMap<Int, AtomicBoolean>()
    private val nextHandle = AtomicInteger(1)
    private val worker = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "speechwarp-voice").apply { isDaemon = true }
    }

    /** Makes any voice by id: Android's own, or an engine package's. */
    private val factory = VoiceFactory { id ->
        when {
            id.startsWith(AndroidSentenceVoice.ID_PREFIX) -> AndroidSentenceVoice.fromId(context, id)
            else -> VoiceProviders.find(id)?.create(context, id) ?: throw IllegalArgumentException(
                "No engine for the voice \"$id\". Voices are \"android:...\"; \"espeak:...\" needs " +
                    "react-native-speechwarp-voice-espeak and \"kokoro:...\" react-native-speechwarp-voice-kokoro."
            )
        }
    }

    override fun listVoices(promise: Promise) {
        worker.execute {
            try {
                val voices = AndroidSentenceVoice.voices(context).map {
                    VoiceInfo(
                        id = it.id,
                        name = it.name,
                        language = it.locale.toLanguageTag(),
                        engine = "android",
                        installed = it.isInstalled,
                        requiresNetwork = it.requiresNetwork,
                    )
                } + VoiceProviders.all().flatMap { it.voices(context) }
                val array = Arguments.createArray()
                for (voice in voices) {
                    array.pushMap(Arguments.createMap().apply {
                        putString("id", voice.id)
                        putString("name", voice.name)
                        putString("language", voice.language)
                        putString("engine", voice.engine)
                        putBoolean("installed", voice.installed)
                        putBoolean("requiresNetwork", voice.requiresNetwork)
                        putBoolean("keepsSpoken", voice.keepsSpoken)
                    })
                }
                promise.resolve(array)
            } catch (e: Throwable) {
                promise.reject("speechwarp_voices", e.message ?: e.toString(), e)
            }
        }
    }

    override fun createReader(text: String, voiceId: String, options: ReadableMap, promise: Promise) {
        worker.execute {
            try {
                val aheadToDisk = AtomicBoolean(options.bool("speakAheadToDisk") ?: false)
                val cacheDirectory = when {
                    options.bool("cache") == false -> null
                    options.string("cacheDirectory") != null -> File(options.string("cacheDirectory")!!)
                    else -> VoiceCache.defaultDirectory(context)
                }
                val defaults = VoicedTextOptions()
                val reader = VoicedText(
                    text, voiceId, factory,
                    VoicedTextOptions(
                        sampleRate = options.number("sampleRate")?.toInt(),
                        speedUp = options.bool("speedUp") ?: true,
                        lookahead = options.number("lookahead") ?: defaults.lookahead,
                        keptLookahead = options.number("keptLookahead") ?: defaults.keptLookahead,
                        secondsPerCharacter = options.number("secondsPerCharacter") ?: defaults.secondsPerCharacter,
                        cacheDirectory = cacheDirectory,
                        speakAheadToDisk = { aheadToDisk.get() },
                        locale = options.string("language")?.let { Locale.forLanguageTag(it) },
                    ),
                )
                options.number("speed")?.let { reader.speed = it.toFloat() }
                val handle = nextHandle.getAndIncrement()
                val interval = ((options.number("positionInterval") ?: 0.1) * 1000).toLong().coerceAtLeast(16)
                val player = ReaderPlayer(
                    reader, interval,
                    onState = { emitOnState(stateMap(handle, it)) },
                    onError = { error ->
                        emitOnError(Arguments.createMap().apply {
                            putInt("reader", handle)
                            putString("message", error.message ?: error.toString())
                        })
                    },
                )
                players[handle] = player
                aheadToDiskFlags[handle] = aheadToDisk
                promise.resolve(Arguments.createMap().apply {
                    putInt("handle", handle)
                    putInt("sampleRate", reader.sampleRate)
                    putDouble("duration", reader.duration)
                    putInt("sentenceCount", reader.sentences.size)
                    putString("voiceId", reader.voiceId)
                })
            } catch (e: Throwable) {
                promise.reject("speechwarp_reader", e.message ?: e.toString(), e)
            }
        }
    }

    private fun player(handle: Double): ReaderPlayer =
        players[handle.toInt()] ?: throw IllegalArgumentException("No reader ${handle.toInt()}: it was released")

    override fun play(handle: Double) = player(handle).play()

    override fun pause(handle: Double) = player(handle).pause()

    override fun seekToCharacter(handle: Double, character: Double) = player(handle).seekToCharacter(character.toInt())

    override fun seekToTime(handle: Double, seconds: Double) = player(handle).seekToTime(seconds)

    override fun setSpeed(handle: Double, speed: Double) {
        player(handle).reader.speed = speed.toFloat()
    }

    override fun setVoice(handle: Double, voiceId: String) = player(handle).reader.setVoice(voiceId)

    override fun configure(handle: Double, settings: ReadableMap) {
        player(handle).reader.configure { stream ->
            settings.number("nonlinear")?.let { stream.nonlinear = it.toFloat() }
            settings.number("pauseCap")?.let { stream.pauseCap = it.toFloat() }
            settings.bool("keepSpeed")?.let { stream.keepSpeed = it }
            settings.number("speedFloor")?.let { stream.speedFloor = it.toFloat() }
            settings.number("rhythmGap")?.let { stream.rhythmGap = it.toFloat() }
            settings.number("rhythmRate")?.let { stream.rhythmRate = it.toFloat() }
            settings.number("heardPause")?.let {
                stream.setHeardPause(it.toFloat(), (settings.number("heardPauseFrom") ?: 0.0).toFloat())
            }
            settings.number("floorBlend")?.let {
                stream.setFloorBlend(
                    it.toFloat(),
                    (settings.number("floorBlendFrom") ?: 0.0).toFloat(),
                    (settings.number("floorBlendFull") ?: 0.0).toFloat(),
                )
            }
        }
    }

    override fun setSpeakAheadToDisk(handle: Double, enabled: Boolean) {
        player(handle)
        aheadToDiskFlags[handle.toInt()]?.set(enabled)
    }

    override fun getState(handle: Double): WritableMap = stateMap(handle.toInt(), player(handle).snapshot())

    override fun getSentences(handle: Double): WritableArray {
        val array = Arguments.createArray()
        for (sentence in player(handle).reader.sentences) {
            array.pushMap(Arguments.createMap().apply {
                putInt("start", sentence.start)
                putInt("length", sentence.length)
            })
        }
        return array
    }

    override fun releaseReader(handle: Double) {
        val player = players.remove(handle.toInt()) ?: return
        aheadToDiskFlags.remove(handle.toInt())
        worker.execute { player.release() }
    }

    override fun defaultCacheDirectory(): String = VoiceCache.defaultDirectory(context).path

    override fun invalidate() {
        for (handle in players.keys.toList()) players.remove(handle)?.release()
        worker.shutdown()
        super.invalidate()
    }

    private fun stateMap(handle: Int, state: ReaderSnapshot): WritableMap = Arguments.createMap().apply {
        putInt("reader", handle)
        putInt("character", state.character)
        putInt("sentence", state.sentence)
        putDouble("time", state.time)
        putBoolean("waiting", state.waiting)
        putBoolean("playing", state.playing)
        putBoolean("finished", state.finished)
    }

    private fun ReadableMap.number(key: String): Double? = if (hasKey(key) && !isNull(key)) getDouble(key) else null
    private fun ReadableMap.bool(key: String): Boolean? = if (hasKey(key) && !isNull(key)) getBoolean(key) else null
    private fun ReadableMap.string(key: String): String? = if (hasKey(key) && !isNull(key)) getString(key) else null

    companion object {
        const val NAME = NativeSpeechwarpVoiceSpec.NAME
    }
}
