package io.github.fredgaffey.speechwarp.reactnative.voice

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import io.github.fredgaffey.speechwarp.voice.VoicedText

/** Where a reader is, as the state event reports it. */
data class ReaderSnapshot(
    val character: Int,
    val sentence: Int,
    val time: Double,
    val waiting: Boolean,
    val playing: Boolean,
    val finished: Boolean,
)

/**
 * Plays a [VoicedText] with an [AudioTrack] on a thread of its own, and reports what is being heard.
 *
 * The position comes from the frames the track has actually played ([AudioTrack.getPlaybackHeadPosition]), mapped to
 * the text by [VoicedText.characterAt], so it follows the sound rather than what has been handed to the track.
 */
internal class ReaderPlayer(
    val reader: VoicedText,
    private val positionIntervalMillis: Long,
    private val onState: (ReaderSnapshot) -> Unit,
    private val onError: (Throwable) -> Unit,
) {
    private val lock = Object()
    private val track: AudioTrack
    private val chunk = FloatArray(maxOf(256, reader.sampleRate / 50)) // 20 ms
    private val starts = reader.sentences.map { it.start }.toIntArray()
    private var pending = 0 // frames of chunk not yet in the track
    private var pendingAt = 0
    private var base = 0L // the reader's frame at the last seek (or 0)
    private var written = 0L // frames given to the track since then
    private var playing = false
    private var finished = false
    private var released = false
    private var lastError: Throwable? = null
    private var lastReported: ReaderSnapshot? = null
    private val thread: Thread

    init {
        val minimum = AudioTrack.getMinBufferSize(reader.sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(reader.sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            // About 0.2 s: enough to ride out a busy moment, little enough that a change of speed is heard soon.
            .setBufferSizeInBytes(maxOf(minimum, reader.sampleRate / 5 * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        thread = Thread({ run() }, "speechwarp-voice player").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    fun play() {
        synchronized(lock) {
            if (released) return
            if (finished) seekLocked(0) // played to the end: play again from the start
            playing = true
            track.play()
            lock.notifyAll()
        }
        report(force = true)
    }

    fun pause() {
        synchronized(lock) {
            if (released) return
            playing = false
            track.pause()
        }
        report(force = true)
    }

    fun seekToCharacter(character: Int) {
        synchronized(lock) {
            if (released) return
            seekLocked(character)
        }
        report(force = true)
    }

    fun seekToTime(seconds: Double) =
        seekToCharacter((seconds / reader.secondsPerCharacter).coerceIn(0.0, reader.text.length.toDouble()).toInt())

    private fun seekLocked(character: Int) {
        // What the track holds is from before the seek: drop it.
        track.pause()
        track.flush()
        pending = 0
        base = reader.seekToCharacter(character)
        written = 0
        finished = false
        if (playing) track.play()
    }

    fun snapshot(): ReaderSnapshot = synchronized(lock) { snapshotLocked() }

    private fun snapshotLocked(): ReaderSnapshot {
        // The head counts frames played since the last flush, as an unsigned 32-bit number.
        val head = if (released) written else minOf(track.playbackHeadPosition.toLong() and 0xFFFFFFFFL, written)
        val character = reader.characterAt(base + head).toInt().coerceIn(0, reader.text.length)
        var sentence = starts.binarySearch(character)
        if (sentence < 0) sentence = maxOf(0, -sentence - 2)
        return ReaderSnapshot(
            character = character,
            sentence = sentence,
            time = character * reader.secondsPerCharacter,
            waiting = playing && !finished && head >= written && pending == 0 && reader.isWaiting,
            playing = playing,
            finished = finished,
        )
    }

    /** Reports the state if it changed (or always with [force]), and any new error. */
    fun report(force: Boolean = false) {
        val (state, error) = synchronized(lock) {
            if (released) return
            val state = snapshotLocked()
            val error = reader.lastError?.takeIf { it !== lastError }
            if (error != null) lastError = error
            val changed = force || state != lastReported
            if (changed) lastReported = state
            Pair(state.takeIf { changed }, error)
        }
        error?.let(onError)
        state?.let(onState)
    }

    fun release() {
        synchronized(lock) {
            if (released) return
            released = true
            playing = false
            lock.notifyAll()
        }
        thread.join(2000)
        track.release()
        reader.close()
    }

    private fun run() {
        var lastReport = 0L
        while (true) {
            var idle: Boolean
            var ended: Boolean
            synchronized(lock) {
                while (!released && !playing) lock.wait()
                if (released) return
                idle = !fill()
                ended = finished
            }
            val now = System.nanoTime()
            if (ended || now - lastReport >= positionIntervalMillis * 1_000_000) {
                lastReport = now
                report()
            }
            if (idle) Thread.sleep(10)
        }
    }

    /** Moves audio from the reader to the track without blocking (with the lock held). False when nothing moved. */
    private fun fill(): Boolean {
        var moved = false
        while (true) {
            if (pending == 0) {
                pending = reader.read(chunk)
                pendingAt = 0
                if (pending == 0) {
                    if (reader.isFinished && !finished) {
                        val head = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                        if (head >= written) {
                            finished = true
                            playing = false
                            track.pause()
                            moved = true
                        }
                    }
                    return moved
                }
            }
            val took = track.write(chunk, pendingAt, pending, AudioTrack.WRITE_NON_BLOCKING)
            if (took < 0) {
                onError(IllegalStateException("AudioTrack.write failed: $took"))
                pending = 0
                return moved
            }
            if (took == 0) return moved // the track is full
            pending -= took
            pendingAt += took
            written += took
            moved = true
        }
    }
}
