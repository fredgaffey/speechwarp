package io.github.fredgaffey.speechwarp.voice

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt

/** The cache's AAC round trip through the platform's MediaCodec, MediaMuxer and MediaExtractor. */
@RunWith(AndroidJUnit4::class)
class VoiceCacheDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val root = File(context.cacheDir, "voice-cache-test")

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    /** A sentence-like burst: a tone of [frequency] fading in and out, then a little silence. */
    private fun burst(frames: Int, frequency: Double, rate: Int) = FloatArray(frames) { i ->
        val envelope = minOf(1.0, i / 400.0, (frames - 400 - i) / 400.0).coerceAtLeast(0.0)
        (0.5 * envelope * sin(2 * PI * frequency * i / rate)).toFloat()
    }

    private fun rms(samples: FloatArray, from: Int = 0, to: Int = samples.size): Double {
        if (to <= from) return 0.0
        var sum = 0.0
        for (i in from until to) sum += samples[i] * samples[i]
        return sqrt(sum / (to - from))
    }

    /** The normalised correlation of [a] and [b] over their common length. */
    private fun correlation(a: FloatArray, b: FloatArray): Double {
        val n = minOf(a.size, b.size)
        var ab = 0.0
        var aa = 0.0
        var bb = 0.0
        for (i in 0 until n) {
            ab += a[i] * b[i]
            aa += a[i] * a[i]
            bb += b[i] * b[i]
        }
        return if (aa == 0.0 || bb == 0.0) 0.0 else ab / sqrt(aa * bb)
    }

    @Test
    fun roundTripsThroughAacWithEverySentenceInPlace() {
        for (rate in intArrayOf(24000, 22050, 16000)) {
            val sentences = listOf(
                burst(rate / 2, 220.0, rate),
                FloatArray(0),
                burst(rate / 3, 440.0, rate),
                burst(rate, 330.0, rate),
                burst(1000, 550.0, rate),
            )
            val cache = VoiceCache("A text for the round trip at $rate.", "test:voice", root)
            cache.save(0, sentences, rate)
            assertTrue(cache.has(0))
            val audio = File(cache.directory, "00000.m4a")
            assertTrue(audio.length() > 0)
            // 32 kbit/s: about 4 kB a second, so well under what 16-bit PCM would take.
            val seconds = sentences.sumOf { it.size } / rate.toDouble()
            assertTrue("${audio.length()} bytes for $seconds s", audio.length() < seconds * 8000 + 4000)

            val loaded = cache.load(0, rate)
            assertNotNull(loaded)
            loaded!!
            assertEquals(sentences.size, loaded.size)
            for (i in sentences.indices) {
                assertEquals("length of sentence $i at $rate", sentences[i].size, loaded[i].size)
                if (sentences[i].isEmpty()) continue
                val c = correlation(sentences[i], loaded[i])
                Log.i("VoiceCacheDeviceTest", "rate $rate sentence $i correlation $c rms ${rms(sentences[i])} -> ${rms(loaded[i])}")
                assertTrue("sentence $i at $rate is out of place or garbled: correlation $c", c > 0.9)
                assertEquals(rms(sentences[i]), rms(loaded[i]), 0.05)
            }

            // Loading at another rate converts.
            val other = cache.load(0, 48000)!!
            assertEquals(sentences[0].size * 48000L / rate, other[0].size.toLong())
            cache.clear()
        }
    }

    @Test
    fun aMinuteOfSpeechSavesAndLoadsQuickly() {
        val rate = 24000
        val sentences = List(40) { burst(rate * 3 / 2, 200.0 + 10 * it, rate) } // 60 s
        val cache = VoiceCache("A minute.", "test:voice", root)
        cache.load(0, rate) // nothing there; and the codec's delay is measured on the first load anyway
        var started = System.nanoTime()
        cache.save(0, sentences, rate)
        val saving = (System.nanoTime() - started) / 1e9
        started = System.nanoTime()
        val loaded = cache.load(0, rate)!!
        val loading = (System.nanoTime() - started) / 1e9
        Log.i("VoiceCacheDeviceTest", "60 s of audio: saved in $saving s, loaded in $loading s")
        assertTrue("saving took $saving s", saving < 20)
        assertTrue("loading took $loading s", loading < 20)
        assertTrue(correlation(sentences[39], loaded[39]) > 0.9)
    }

    @Test
    fun keepsABlockOfNothing() {
        val cache = VoiceCache("Silence.", "test:voice", root)
        cache.save(2, listOf(FloatArray(0), FloatArray(0)), 24000)
        val loaded = cache.load(2, 24000)!!
        assertEquals(2, loaded.size)
        assertTrue(loaded.all { it.isEmpty() })
    }

    @Test
    fun keepsAnOddSampleRateByConvertingIt() {
        val rate = 23000 // not an AAC rate: kept at 24 kHz and converted back
        val sentence = burst(rate, 300.0, rate)
        val cache = VoiceCache("Odd.", "test:odd", root)
        cache.save(0, listOf(sentence), rate)
        val loaded = cache.load(0, rate)!!
        assertTrue(abs(loaded[0].size - sentence.size) <= 2)
        assertTrue(correlation(sentence, loaded[0]) > 0.8)
    }

    @Test
    fun aDamagedFileIsForgotten() {
        val cache = VoiceCache("Damaged.", "test:voice", root)
        cache.save(0, listOf(burst(4000, 300.0, 16000)), 16000)
        File(cache.directory, "00000.m4a").writeBytes(ByteArray(100) { 7 })
        assertNull(cache.load(0, 16000))
        assertFalse(cache.has(0))
    }
}
