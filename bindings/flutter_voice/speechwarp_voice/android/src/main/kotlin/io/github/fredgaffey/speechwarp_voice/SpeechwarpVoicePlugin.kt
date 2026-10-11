package io.github.fredgaffey.speechwarp_voice

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * speechwarp_voice on Android: Dart's [MethodChannel] "speechwarp_voice" makes and drives readers ([ReaderPlayer], a
 * speechwarp-voice VoicedText played through an AudioTrack), and the [EventChannel] "speechwarp_voice/positions"
 * reports where each one is.
 *
 * Making a voice and listing voices block (Android's text-to-speech service starts asynchronously and reports to the
 * main thread), so they run on a background thread and answer on the main thread.
 */
class SpeechwarpVoicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var engines: Engines
    private val main = Handler(Looper.getMainLooper())
    private var background: ExecutorService? = null
    private val readers = HashMap<Int, ReaderPlayer>()
    private var nextId = 1
    private var sink: EventChannel.EventSink? = null
    private var ticking = false

    companion object {
        /**
         * The phonemizer for Kokoro voices when the app does not include speechwarp_voice_espeak (eSpeak NG is
         * GPL-3.0-or-later; an app that cannot be GPL supplies its own). Set it from the app's own Kotlin, such as in
         * MainActivity, before making a reader with a "kokoro:" voice. When it is null, eSpeak's phonemizer is used if
         * speechwarp_voice_espeak is there.
         */
        @JvmStatic
        @Volatile
        var phonemizer: Phonemizer? = null

        private const val TICK_MILLIS = 50L
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        engines = Engines(context)
        background = Executors.newSingleThreadExecutor { Thread(it, "speechwarp_voice").apply { isDaemon = true } }
        methods = MethodChannel(binding.binaryMessenger, "speechwarp_voice")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "speechwarp_voice/positions")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        val all = readers.values.toList()
        readers.clear()
        background?.let { executor ->
            executor.execute { all.forEach { it.close() } }
            executor.shutdown()
        }
        background = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        tick()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listVoices" -> inBackground(result) {
                    engines.voices(options(call.argument<String>("kokoroDirectory"), call.argument<String>("kokoroModelFile")))
                }
                "create" -> create(call, result)
                else -> {
                    val id = call.argument<Int>("id") ?: throw IllegalArgumentException("No reader id")
                    val reader = readers[id] ?: throw IllegalStateException("No reader $id: it has been disposed")
                    when (call.method) {
                        "play" -> reader.play()
                        "pause" -> reader.pause()
                        "seek" -> reader.seek(call.argument<Int>("character") ?: 0)
                        "setSpeed" -> reader.setSpeed(number(call.argument("speed")))
                        "configure" -> reader.configure(call.argument<Map<String, Any?>>("settings") ?: emptyMap())
                        "setVoice" -> reader.setVoice(call.argument<String>("voiceId") ?: throw IllegalArgumentException("No voiceId"))
                        "position" -> {}
                        "dispose" -> {
                            readers.remove(id)
                            // Closing waits for the writer thread; keep it off the main thread.
                            background?.execute { reader.close() } ?: reader.close()
                            result.success(null)
                            return
                        }
                        else -> {
                            result.notImplemented()
                            return
                        }
                    }
                    result.success(reader.position(id))
                    tick()
                }
            }
        } catch (e: Exception) {
            result.error(errorCode(e), e.message ?: e.toString(), null)
        }
    }

    private fun create(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text") ?: throw IllegalArgumentException("No text")
        val voiceId = call.argument<String>("voiceId") ?: throw IllegalArgumentException("No voiceId")
        val options = call.argument<Map<String, Any?>>("options") ?: emptyMap()
        val id = nextId++
        inBackground(result) {
            val engineOptions = options(options["kokoroDirectory"] as String?, options["kokoroModelFile"] as String?)
            val cacheDirectory = if (options["cache"] as Boolean? != false) {
                (options["cacheDirectory"] as String?)?.let(::File) ?: File(context.cacheDir, "speechwarp-voice")
            } else null
            val reader = ReaderPlayer(text, voiceId, engines.factory(engineOptions), options, cacheDirectory)
            main.post {
                // Disposed while being made: the engine went away.
                if (background == null) background { reader.close() } else readers[id] = reader
            }
            mapOf(
                "id" to id,
                "sampleRate" to reader.sampleRate,
                "sentences" to reader.sentenceRanges(),
            )
        }
    }

    private fun background(block: () -> Unit) = Thread(block, "speechwarp_voice close").start()

    private fun options(kokoroDirectory: String?, kokoroModelFile: String?): Map<String, Any?> = mapOf(
        "kokoroDirectory" to kokoroDirectory,
        "kokoroModelFile" to kokoroModelFile,
        "phonemizer" to phonemizer,
    )

    private fun <T> inBackground(result: MethodChannel.Result, work: () -> T) {
        val executor = background ?: return result.error("closed", "The plugin is detached", null)
        executor.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error(errorCode(e), e.message ?: e.toString(), null) }
            }
        }
    }

    // Sends every reader's position while any is playing, TICK_MILLIS apart, and once more after the last stops.
    private fun tick() {
        if (ticking) return
        ticking = true
        main.post(object : Runnable {
            override fun run() {
                val sink = sink
                var active = false
                for ((id, reader) in readers) {
                    val changed = reader.takeChanged()
                    if (reader.isPlaying || changed) {
                        sink?.success(reader.position(id))
                        active = active || reader.isPlaying
                    }
                }
                if (active && sink != null) main.postDelayed(this, TICK_MILLIS) else ticking = false
            }
        })
    }

    private fun number(value: Any?): Float = (value as? Number)?.toFloat() ?: throw IllegalArgumentException("Not a number: $value")

    private fun errorCode(e: Throwable): String = when (e) {
        is EngineMissingException -> "voice"
        is KokoroSetupException -> "kokoro"
        is IllegalArgumentException -> "argument"
        is IllegalStateException -> "state"
        else -> "error"
    }
}
