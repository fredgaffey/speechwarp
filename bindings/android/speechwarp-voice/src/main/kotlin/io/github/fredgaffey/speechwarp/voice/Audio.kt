package io.github.fredgaffey.speechwarp.voice

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Converting mono audio from one sample rate to another. */
internal object AudioResampling {
    /** Linear interpolation: good enough for speech going from 22,050 to 24,000 and the like. */
    fun linear(samples: FloatArray, source: Int, target: Int, offset: Int = 0, length: Int = samples.size - offset): FloatArray {
        if (source == target || length == 0) return samples.copyOfRange(offset, offset + length)
        val result = FloatArray((length.toLong() * target / source).toInt())
        for (i in result.indices) {
            val x = i.toDouble() * source / target
            val j = x.toInt()
            val f = (x - j).toFloat()
            result[i] = if (j + 1 < length) samples[offset + j] * (1 - f) + samples[offset + j + 1] * f else samples[offset + length - 1]
        }
        return result
    }
}

/** Mono samples at a sample rate. */
internal class Pcm(val samples: FloatArray, val sampleRate: Int)

/** Reading WAV files: what Android's text-to-speech writes. */
internal object Wav {
    private const val PCM = 1
    private const val FLOAT = 3
    private const val EXTENSIBLE = 0xFFFE

    /**
     * The audio of a RIFF WAVE file, mixed to mono: 8, 16, 24 or 32-bit PCM, or 32-bit float. A data chunk whose
     * length is 0 or runs past the end (as a streaming writer leaves it) is taken to the end of the file.
     */
    fun read(bytes: ByteArray): Pcm {
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        if (bytes.size < 12 || tag(buffer, 0) != "RIFF" || tag(buffer, 8) != "WAVE") throw IOException("Not a WAV file")
        var at = 12
        var format = -1
        var channels = 0
        var rate = 0
        var bits = 0
        while (at + 8 <= bytes.size) {
            val id = tag(buffer, at)
            val size = buffer.getInt(at + 4).toLong() and 0xFFFFFFFFL
            val body = at + 8
            when (id) {
                "fmt " -> {
                    if (size < 16 || body + 16 > bytes.size) throw IOException("A WAV file with a short fmt chunk")
                    format = buffer.getShort(body).toInt() and 0xFFFF
                    channels = buffer.getShort(body + 2).toInt() and 0xFFFF
                    rate = buffer.getInt(body + 4)
                    bits = buffer.getShort(body + 14).toInt() and 0xFFFF
                    if (format == EXTENSIBLE && size >= 26 && body + 26 <= bytes.size) {
                        format = buffer.getShort(body + 24).toInt() and 0xFFFF // the sub-format GUID's first two bytes
                    }
                }
                "data" -> {
                    if (format < 0) throw IOException("A WAV file with its data before its format")
                    val length = if (size == 0L || body + size > bytes.size) (bytes.size - body).toLong() else size
                    return Pcm(decode(buffer, body, length.toInt(), format, channels, bits), rate)
                }
            }
            if (body + size >= bytes.size) break
            at = body + size.toInt() + (size.toInt() and 1) // chunks are padded to an even length
        }
        throw IOException("A WAV file with no data")
    }

    private fun decode(buffer: ByteBuffer, start: Int, length: Int, format: Int, channels: Int, bits: Int): FloatArray {
        if (channels < 1 || bits <= 0 || bits % 8 != 0) throw IOException("A WAV file with $channels channels of $bits bits")
        val width = bits / 8
        if (!(format == PCM && width in 1..4) && !(format == FLOAT && width == 4)) {
            throw IOException("A WAV file in format $format with $bits bits, which is not supported")
        }
        val frames = length / (width * channels)
        val out = FloatArray(frames)
        var at = start
        for (i in 0 until frames) {
            var sum = 0f
            for (c in 0 until channels) {
                sum += when {
                    format == FLOAT -> buffer.getFloat(at)
                    width == 1 -> ((buffer.get(at).toInt() and 0xFF) - 128) / 128f
                    width == 2 -> buffer.getShort(at) / 32768f
                    width == 3 -> ((buffer.get(at).toInt() and 0xFF) or ((buffer.get(at + 1).toInt() and 0xFF) shl 8) or
                        (buffer.get(at + 2).toInt() shl 16)) / 8388608f
                    else -> (buffer.getInt(at) / 2147483648.0).toFloat()
                }
                at += width
            }
            out[i] = sum / channels
        }
        return out
    }

    private fun tag(buffer: ByteBuffer, at: Int): String =
        String(CharArray(4) { (buffer.get(at + it).toInt() and 0xFF).toChar() })
}

/** Floats, -1 to 1, as 16-bit samples. */
internal fun toShort(sample: Float): Short = (sample.coerceIn(-1f, 1f) * 32767f).let { Math.round(it) }.toShort()
