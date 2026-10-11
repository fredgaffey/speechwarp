package io.github.fredgaffey.speechwarp.voice

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicInteger

/**
 * A voice for the tests: each sentence becomes [framesPerCharacter] frames a character of the constant [level], so
 * which voice spoke what can be told from the audio.
 */
internal class FakeVoice(
    override val id: String,
    override val sampleRate: Int = 16000,
    private val level: Float = 0.5f,
    override val keepsSpoken: Boolean = false,
    private val delayMillis: Long = 0,
    private val framesPerCharacter: Int = 160,
    private val failOn: String? = null,
) : SentenceVoice {
    val spoken = AtomicInteger()
    @Volatile var closed = false
    @Volatile var closedOn: Thread? = null
    @Volatile var spokeOn: Thread? = null
    @Volatile var speaking = false

    override fun speak(sentence: String): FloatArray {
        check(!closed) { "spoken to after close" }
        speaking = true
        try {
            spokeOn = Thread.currentThread()
            if (delayMillis > 0) Thread.sleep(delayMillis)
            if (failOn != null && sentence.contains(failOn)) throw IllegalStateException("cannot say $sentence")
            spoken.incrementAndGet()
            return FloatArray(sentence.trim().length * framesPerCharacter) { level }
        } finally {
            speaking = false
        }
    }

    override fun close() {
        check(!speaking) { "closed while speaking" }
        closed = true
        closedOn = Thread.currentThread()
    }
}

/** Keeps a block as raw floats: the unit tests have no MediaCodec. */
internal object RawCodec : VoiceCache.Codec {
    override val extension = "raw"

    override fun write(file: File, samples: FloatArray, sampleRate: Int) {
        val buffer = ByteBuffer.allocate(4 + samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(sampleRate)
        for (s in samples) buffer.putFloat(s)
        file.writeBytes(buffer.array())
    }

    override fun read(file: File): Pcm {
        val buffer = ByteBuffer.wrap(file.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        val rate = buffer.getInt()
        return Pcm(FloatArray(buffer.remaining() / 4) { buffer.getFloat() }, rate)
    }
}

internal fun sentencesText(count: Int): String =
    (1..count).joinToString(" ") { "Sentence number $it is here." }

internal fun waitFor(timeoutMillis: Long = 10_000, condition: () -> Boolean) {
    val end = System.currentTimeMillis() + timeoutMillis
    while (!condition()) {
        if (System.currentTimeMillis() > end) throw AssertionError("timed out waiting")
        Thread.sleep(5)
    }
}
