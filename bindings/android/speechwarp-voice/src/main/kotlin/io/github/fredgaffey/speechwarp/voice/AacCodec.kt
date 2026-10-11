package io.github.fredgaffey.speechwarp.voice

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Build
import java.io.File
import java.io.IOException
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.sqrt

/**
 * AAC-LC at 32 kbit/s, mono, in an MPEG-4 file, through the platform's MediaCodec and MediaMuxer; read back through
 * MediaExtractor and MediaCodec.
 *
 * An AAC encoder starts its output with priming samples, which the decoder gives back as silence before the audio
 * (2048 with Android's own encoder; the extractor reports nothing, as MediaMuxer writes no edit list). So that every
 * sentence stays in place, [read] removes them. How many is measured once for each sample rate by encoding and
 * decoding a probe, so an encoder with another delay, or a decoder that removes it itself, is handled too.
 */
internal object AacCodec : VoiceCache.Codec {
    private const val MIME = MediaFormat.MIMETYPE_AUDIO_AAC
    private const val BIT_RATE = 32000
    private const val FRAME = 1024 // samples in an AAC-LC frame
    private const val TIMEOUT_US = 10_000L
    private const val DEFAULT_DELAY = 2048

    // The sample rates AAC defines; audio at another rate is kept at the next one up (or 48 kHz).
    private val rates = intArrayOf(8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000)

    override val extension = "m4a"

    override fun storedRate(sampleRate: Int): Int = rates.firstOrNull { it >= sampleRate } ?: 48000

    override fun write(file: File, samples: FloatArray, sampleRate: Int) {
        require(sampleRate in rates) { "AAC has no sample rate $sampleRate" }
        val rate = sampleRate
        // A muxer with no samples cannot be stopped: an empty block holds one frame of silence (its lengths say 0).
        val pcm = if (samples.isEmpty()) FloatArray(FRAME) else samples

        val format = MediaFormat.createAudioFormat(MIME, rate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val encoder = MediaCodec.createEncoderByType(MIME)
        var muxer: MediaMuxer? = null
        var started = false
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val info = MediaCodec.BufferInfo()
            var fed = 0
            var inputDone = false
            var track = -1
            var done = false
            while (!done) {
                var gave = false
                if (!inputDone) {
                    val index = encoder.dequeueInputBuffer(0)
                    if (index >= 0) {
                        gave = true
                        val buffer = encoder.getInputBuffer(index) ?: throw IOException("The AAC encoder gave no input buffer")
                        buffer.clear()
                        val count = minOf(pcm.size - fed, buffer.remaining() / 2)
                        val time = fed * 1_000_000L / rate
                        if (count <= 0) {
                            encoder.queueInputBuffer(index, 0, 0, time, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val shorts = buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
                            for (i in 0 until count) shorts.put(toShort(pcm[fed + i]))
                            encoder.queueInputBuffer(index, 0, count * 2, time, 0)
                            fed += count
                        }
                    }
                }
                // Everything ready is taken; it waits only when it could give no input either.
                var wait = if (gave) 0L else TIMEOUT_US
                while (!done) {
                    val out = encoder.dequeueOutputBuffer(info, wait)
                    if (out == MediaCodec.INFO_TRY_AGAIN_LATER) break
                    wait = 0
                    if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        started = true
                    } else if (out >= 0) {
                        val buffer = encoder.getOutputBuffer(out) ?: throw IOException("The AAC encoder gave no output buffer")
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                        if (info.size > 0) {
                            if (!started) throw IOException("The AAC encoder gave audio before its format")
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            muxer.writeSampleData(track, buffer, info)
                        }
                        encoder.releaseOutputBuffer(out, false)
                        done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    }
                }
            }
        } finally {
            try {
                encoder.stop()
            } catch (_: Exception) {
            }
            encoder.release()
            if (muxer != null) {
                try {
                    if (started) muxer.stop()
                } finally {
                    muxer.release()
                }
            }
        }
    }

    override fun read(file: File): Pcm {
        val raw = readRaw(file)
        val delay = minOf(raw.samples.size, delay(raw.sampleRate, file.parentFile))
        return Pcm(raw.samples.copyOfRange(delay, raw.samples.size), raw.sampleRate)
    }

    /** The file's audio as decoded, priming and all. */
    private fun readRaw(file: File): Pcm {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IOException("No audio in $file")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            try {
                decoder.configure(format, null, null, 0)
                decoder.start()
                return decode(extractor, decoder, format)
            } finally {
                try {
                    decoder.stop()
                } catch (_: Exception) {
                }
                decoder.release()
            }
        } finally {
            extractor.release()
        }
    }

    private fun decode(extractor: MediaExtractor, decoder: MediaCodec, trackFormat: MediaFormat): Pcm {
        var rate = trackFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = trackFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        var float = false
        var out = FloatArray(maxOf(FRAME, (trackFormat.durationUs() * rate / 1_000_000L).toInt() + 4 * FRAME))
        var size = 0
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var done = false
        while (!done) {
            var gave = false
            if (!inputDone) {
                val index = decoder.dequeueInputBuffer(0)
                if (index >= 0) {
                    gave = true
                    val buffer = decoder.getInputBuffer(index) ?: throw IOException("The decoder gave no input buffer")
                    val count = extractor.readSampleData(buffer, 0)
                    if (count < 0) {
                        decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(index, 0, count, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }
            var wait = if (gave) 0L else TIMEOUT_US
            while (!done) {
                val index = decoder.dequeueOutputBuffer(info, wait)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) break
                wait = 0
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val format = decoder.outputFormat
                        rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        float = Build.VERSION.SDK_INT >= 24 && format.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            format.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                    }
                    index >= 0 -> {
                        val buffer = decoder.getOutputBuffer(index) ?: throw IOException("The decoder gave no output buffer")
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        buffer.order(ByteOrder.LITTLE_ENDIAN)
                        val frames = info.size / ((if (float) 4 else 2) * channels)
                        if (size + frames > out.size) out = out.copyOf(maxOf(out.size * 2, size + frames))
                        if (float) {
                            val floats = buffer.asFloatBuffer()
                            for (i in 0 until frames) {
                                var sum = 0f
                                for (c in 0 until channels) sum += floats.get()
                                out[size++] = sum / channels
                            }
                        } else {
                            val shorts = buffer.asShortBuffer()
                            for (i in 0 until frames) {
                                var sum = 0f
                                for (c in 0 until channels) sum += shorts.get() / 32768f
                                out[size++] = sum / channels
                            }
                        }
                        decoder.releaseOutputBuffer(index, false)
                        done = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    }
                }
            }
        }
        return Pcm(out.copyOf(size), rate)
    }

    private val delays = HashMap<Int, Int>()

    /** The priming samples the encoder adds and the decoder keeps, at [rate]; measured the first time. */
    private fun delay(rate: Int, folder: File?): Int = synchronized(delays) {
        delays.getOrPut(rate) { measureDelay(rate, folder) }
    }

    /** Encodes and decodes a burst of noise and finds where it comes back; 2048 (Android's encoder) if that fails. */
    private fun measureDelay(rate: Int, folder: File?): Int {
        val probe = File(folder, "aac-delay-probe-${UUID.randomUUID()}.m4a")
        return try {
            val random = java.util.Random(1)
            val signal = FloatArray(8192) { if (it in 2048 until 6144) random.nextFloat() - 0.5f else 0f }
            write(probe, signal, rate)
            val back = readRaw(probe).samples
            var best = DEFAULT_DELAY
            var bestScore = 0.5
            for (lag in 0..4096) {
                var ab = 0.0
                var aa = 0.0
                var bb = 0.0
                for (i in 2048 until minOf(6144, back.size - lag)) {
                    ab += signal[i] * back[i + lag]
                    aa += signal[i] * signal[i]
                    bb += back[i + lag] * back[i + lag]
                }
                val score = if (aa > 0 && bb > 0) ab / sqrt(aa * bb) else 0.0
                if (score > bestScore) {
                    bestScore = score
                    best = lag
                }
            }
            best
        } catch (e: Exception) {
            DEFAULT_DELAY
        } finally {
            probe.delete()
        }
    }

    private fun MediaFormat.durationUs(): Long = if (containsKey(MediaFormat.KEY_DURATION)) getLong(MediaFormat.KEY_DURATION) else 0L
}
