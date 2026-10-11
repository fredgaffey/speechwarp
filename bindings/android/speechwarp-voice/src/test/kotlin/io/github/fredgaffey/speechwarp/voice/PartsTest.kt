package io.github.fredgaffey.speechwarp.voice

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale

class PartsTest {
    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun splitsSentencesAndKeepsTheirPlaces() {
        val text = "  Hello there. How are you?  Fine!\n\nThe end"
        val sentences = Sentence.split(text, Locale.ENGLISH)
        assertEquals(4, sentences.size)
        for (s in sentences) assertEquals(s.text, text.substring(s.start, s.end))
        assertTrue(sentences[0].text.contains("Hello there."))
        assertEquals("The end", sentences[3].text)
        assertTrue(Sentence.split("   \n ").isEmpty())
    }

    @Test
    fun cutsLongSentencesAtACommaOrSpace() {
        val long = (1..120).joinToString(", ") { "word$it" } + "."
        val sentences = Sentence.split(long, Locale.ENGLISH)
        assertTrue(sentences.size > 1)
        assertTrue(sentences.all { it.length <= 400 })
        assertTrue(sentences.dropLast(1).all { it.text.endsWith(",") })
        assertEquals(long, sentences.joinToString("") { it.text })

        val noBreaks = "x".repeat(1000)
        assertEquals(listOf(400, 400, 200), Sentence.split(noBreaks).map { it.length })
    }

    @Test
    fun keysAreTheCSharpOnes() {
        // The first 16 hex digits of SHA-256("hello").
        assertEquals("2cf24dba5fb0a30e", VoiceCache.textKey("hello"))
        assertEquals("android-en-us-x-iol-local-1.5-1", VoiceCache.fileName("android:en-us-x-iol-local/1.5/1"))
        assertEquals("-hidden", VoiceCache.fileName(".hidden"))
        assertEquals(0, VoiceCache.blockOf(39))
        assertEquals(1, VoiceCache.blockOf(40))
        assertEquals(2, VoiceCache.blockCount(41))
        assertEquals(0, VoiceCache.blockCount(0))
    }

    @Test
    fun cacheKeepsBlocksWithTheirLengths() {
        val root = folder.newFolder()
        val cache = VoiceCache("some text", "kokoro:af_heart", root, RawCodec)
        assertEquals(File(File(root, VoiceCache.textKey("some text")), "kokoro-af_heart"), cache.directory)
        assertFalse(cache.has(3))
        assertNull(cache.load(3, 24000))
        val sentences = listOf(FloatArray(100) { 0.1f }, FloatArray(0), FloatArray(50) { -0.2f })
        cache.save(3, sentences, 24000)
        assertTrue(cache.has(3))
        assertEquals("[100,0,50]", File(cache.directory, "00003.json").readText())
        assertTrue(File(cache.directory, "00003.raw").isFile)
        val loaded = cache.load(3, 24000)!!
        assertEquals(3, loaded.size)
        for (i in sentences.indices) assertArrayEquals(sentences[i], loaded[i], 0f)
        assertEquals(50, cache.load(3, 12000)!![0].size)
        assertEquals(cache.directory.listFiles()!!.size, 2) // no temporary files left
        cache.remove(3)
        assertFalse(cache.has(3))
        cache.save(0, sentences, 24000)
        cache.clear()
        assertFalse(cache.directory.exists())
    }

    @Test
    fun aBrokenBlockIsForgotten() {
        val cache = VoiceCache("t", "v", folder.newFolder(), RawCodec)
        cache.save(0, listOf(FloatArray(10)), 16000)
        File(cache.directory, "00000.json").writeText("not json")
        assertNull(cache.load(0, 16000))
        assertFalse(cache.has(0))
    }

    @Test
    fun resamplesLinearly() {
        val up = AudioResampling.linear(floatArrayOf(0f, 1f, 0f, -1f), 1, 2)
        assertEquals(8, up.size)
        assertEquals(0.5f, up[1], 1e-6f)
        val same = floatArrayOf(1f, 2f)
        assertArrayEquals(same, AudioResampling.linear(same, 5, 5), 0f)
        assertEquals(2, AudioResampling.linear(FloatArray(4), 24000, 12000).size)
    }

    private fun wav(format: Int, channels: Int, rate: Int, bits: Int, data: ByteArray, dataSize: Int = data.size, extra: Boolean = false): ByteArray {
        val buffer = ByteBuffer.allocate(64 + data.size).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray()).putInt(0).put("WAVE".toByteArray())
        if (extra) buffer.put("LIST".toByteArray()).putInt(3).put(byteArrayOf(1, 2, 3, 0))
        buffer.put("fmt ".toByteArray()).putInt(16).putShort(format.toShort()).putShort(channels.toShort())
            .putInt(rate).putInt(rate * channels * bits / 8).putShort((channels * bits / 8).toShort()).putShort(bits.toShort())
        buffer.put("data".toByteArray()).putInt(dataSize).put(data)
        return buffer.array().copyOf(buffer.position())
    }

    @Test
    fun readsWavFiles() {
        val pcm16 = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putShort(16384).putShort(-16384).putShort(32767).putShort(0).array()
        val mono = Wav.read(wav(1, 1, 22050, 16, pcm16, extra = true))
        assertEquals(22050, mono.sampleRate)
        assertArrayEquals(floatArrayOf(0.5f, -0.5f, 32767 / 32768f, 0f), mono.samples, 1e-6f)

        val stereo = Wav.read(wav(1, 2, 16000, 16, pcm16))
        assertArrayEquals(floatArrayOf(0f, 32767 / 65536f), stereo.samples, 1e-6f)

        // A streaming writer's header: data length 0, meaning "to the end".
        assertEquals(4, Wav.read(wav(1, 1, 8000, 16, pcm16, dataSize = 0)).samples.size)

        val floats = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putFloat(0.25f).putFloat(-1f).array()
        assertArrayEquals(floatArrayOf(0.25f, -1f), Wav.read(wav(3, 1, 24000, 32, floats)).samples, 0f)

        val pcm8 = byteArrayOf(128.toByte(), 255.toByte(), 0)
        assertArrayEquals(floatArrayOf(0f, 127 / 128f, -1f), Wav.read(wav(1, 1, 8000, 8, pcm8)).samples, 1e-6f)
    }

    @Test(expected = java.io.IOException::class)
    fun refusesWhatIsNotWav() {
        Wav.read("hello, this is not a wav file".toByteArray())
    }

    @Test
    fun androidVoiceIdsCarryTheRateAndPitch() {
        assertEquals("android:en-us-x-iol-local", AndroidSentenceVoice.idFor("en-us-x-iol-local", 1f, 1f))
        assertEquals("android:en-us-x-iol-local/1.5/1", AndroidSentenceVoice.idFor("en-us-x-iol-local", 1.5f, 1f))
        assertEquals("android:default/2/0.8", AndroidSentenceVoice.idFor(null, 2f, 0.8f))
    }
}
