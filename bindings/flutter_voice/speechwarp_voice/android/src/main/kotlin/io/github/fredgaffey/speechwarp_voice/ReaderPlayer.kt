package io.github.fredgaffey.speechwarp_voice

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.github.fredgaffey.speechwarp.voice.VoiceFactory
import io.github.fredgaffey.speechwarp.voice.VoicedText
import io.github.fredgaffey.speechwarp.voice.VoicedTextOptions
import java.io.File
import kotlin.math.max

/**
 * A [VoicedText] played through an [AudioTrack]: a thread of its own takes what the reader has ready and writes it
 * to the track without ever blocking, so pausing and seeking take effect at once. Safe to call from any thread.
 *
 * Made on a background thread: the first voice may block while it starts.
 */
internal class ReaderPlayer(
    text: String,
    voiceId: String,
    factory: VoiceFactory,
    options: Map<String, Any?>,
    cacheDirectory: File?,
) {
    private val reader = VoicedText(
        text, voiceId, factory,
        VoicedTextOptions(
            lookahead = (options["lookahead"] as Number?)?.toDouble() ?: 30.0,
            keptLookahead = (options["keptLookahead"] as Number?)?.toDouble() ?: 120.0,
            secondsPerCharacter = (options["secondsPerCharacter"] as Number?)?.toDouble() ?: (1 / 17.0),
            cacheDirectory = cacheDirectory,
        ),
    )
    val sampleRate = reader.sampleRate

    private val lock = Object()
    private val track: AudioTrack
    private val buffer: FloatArray
    private val writer: Thread
    private var pending = 0 // frames in buffer not yet written to the track
    private var offset = 0
    private var written = 0L // frames written to the track since the last seek
    private var headBase = 0L // the track's playback head at the last seek
    private var seekFrame = 0L // the reader's frame at the last seek
    private var playing = false
    private var finished = false
    private var closed = false
    @Volatile private var changed = true

    init {
        try {
            (options["speed"] as Number?)?.toFloat()?.let { reader.speed = it }
            @Suppress("UNCHECKED_CAST")
            (options["speedUp"] as Map<String, Any?>?)?.let { configure(it) }
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val minimum = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
            // About a fifth of a second of audio in the track: short enough that the position is close to what is heard.
            val bytes = max(minimum, sampleRate / 5 * 4)
            track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(format)
                .setBufferSizeInBytes(bytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            buffer = FloatArray(max(256, sampleRate / 50)) // 20 ms
        } catch (e: Throwable) {
            reader.close()
            throw e
        }
        writer = Thread(::write, "speechwarp_voice player").apply {
            isDaemon = true
            start()
        }
    }

    /** Whether audio is playing (or waiting for the next sentence). */
    val isPlaying: Boolean get() = synchronized(lock) { playing }

    /** True once after anything that the position should report has changed. */
    fun takeChanged(): Boolean {
        val was = changed
        changed = false
        return was
    }

    fun play() = synchronized(lock) {
        check(!closed) { "The reader is closed" }
        if (finished) restart(0)
        playing = true
        track.play()
        changed = true
        lock.notifyAll()
    }

    fun pause() = synchronized(lock) {
        playing = false
        if (!closed) track.pause()
        changed = true
    }

    fun seek(character: Int) = synchronized(lock) {
        check(!closed) { "The reader is closed" }
        restart(character)
        if (playing) track.play()
        changed = true
        lock.notifyAll()
    }

    fun setSpeed(speed: Float) {
        reader.speed = speed
        changed = true
    }

    fun setVoice(voiceId: String) {
        reader.setVoice(voiceId)
        changed = true
    }

    fun configure(settings: Map<String, Any?>) {
        fun f(key: String) = (settings[key] as Number?)?.toFloat()
        reader.configure { stream ->
            f("nonlinear")?.let { stream.nonlinear = it }
            f("pauseCap")?.let { stream.pauseCap = it }
            (settings["keepSpeed"] as Boolean?)?.let { stream.keepSpeed = it }
            f("speedFloor")?.let { stream.speedFloor = it }
            f("rhythmGap")?.let { stream.rhythmGap = it }
            f("rhythmRate")?.let { stream.rhythmRate = it }
            val pause = f("heardPause")
            val pauseFrom = f("heardPauseFrom")
            if (pause != null && pauseFrom != null) stream.setHeardPause(pause, pauseFrom)
            val blend = f("floorBlend")
            val blendFrom = f("floorBlendFrom")
            val blendFull = f("floorBlendFull")
            if (blend != null && blendFrom != null && blendFull != null) stream.setFloorBlend(blend, blendFrom, blendFull)
        }
        changed = true
    }

    /** The sentences as start, length, start, length ... */
    fun sentenceRanges(): IntArray {
        val sentences = reader.sentences
        val ranges = IntArray(sentences.size * 2)
        sentences.forEachIndexed { i, s ->
            ranges[2 * i] = s.start
            ranges[2 * i + 1] = s.length
        }
        return ranges
    }

    /** What is being heard, for Dart's ReaderPosition.fromMap. */
    fun position(id: Int): Map<String, Any?> {
        val character: Int
        val isPlaying: Boolean
        val isFinished: Boolean
        synchronized(lock) {
            val played = if (closed) written else (track.playbackHeadPosition.toLong() and 0xffffffffL) - headBase
            val heard = seekFrame + played.coerceIn(0, written)
            character = reader.characterAt(heard).toInt().coerceIn(0, reader.text.length)
            isPlaying = playing
            isFinished = finished
        }
        return mapOf(
            "reader" to id,
            "character" to character,
            "sentence" to sentenceAt(character),
            "time" to character * reader.secondsPerCharacter,
            "playing" to isPlaying,
            "waiting" to (isPlaying && reader.isWaiting),
            "finished" to isFinished,
            "voiceId" to reader.voiceId,
            "error" to reader.lastError?.let { it.message ?: it.toString() },
        )
    }

    /** Stops the writer, releases the track and closes the reader (and its voices, on the reader's thread). */
    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            playing = false
            lock.notifyAll()
        }
        writer.join(2000)
        track.release()
        reader.close()
    }

    // With the lock held.
    private fun restart(character: Int) {
        track.pause()
        track.flush()
        pending = 0
        written = 0
        finished = false
        seekFrame = reader.seekToCharacter(character)
        headBase = track.playbackHeadPosition.toLong() and 0xffffffffL
    }

    private fun sentenceAt(character: Int): Int {
        val sentences = reader.sentences
        var low = 0
        var high = sentences.size - 1
        while (low < high) {
            val mid = (low + high + 1) / 2
            if (sentences[mid].start <= character) low = mid else high = mid - 1
        }
        return low
    }

    private fun write() {
        while (true) {
            var idle: Boolean
            synchronized(lock) {
                while (!closed && !playing) lock.wait()
                if (closed) return
                if (pending == 0) {
                    pending = reader.read(buffer)
                    offset = 0
                }
                if (pending > 0) {
                    val n = track.write(buffer, offset, pending, AudioTrack.WRITE_NON_BLOCKING)
                    if (n > 0) {
                        offset += n
                        pending -= n
                        written += n
                    }
                    idle = n <= 0 || pending > 0 // the track is full
                } else {
                    idle = true
                    if (reader.isFinished) {
                        val played = (track.playbackHeadPosition.toLong() and 0xffffffffL) - headBase
                        if (played >= written) {
                            finished = true
                            playing = false
                            track.pause()
                            changed = true
                        }
                    }
                }
            }
            if (idle) Thread.sleep(10)
        }
    }
}
