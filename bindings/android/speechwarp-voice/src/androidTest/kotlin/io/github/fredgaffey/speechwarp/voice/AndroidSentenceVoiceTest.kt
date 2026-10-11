package io.github.fredgaffey.speechwarp.voice

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.sqrt

/** Android's own text-to-speech as a sentence voice. Skipped where the device has no engine. */
@RunWith(AndroidJUnit4::class)
class AndroidSentenceVoiceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun needsAnEngine() {
        val engines = AndroidSentenceVoice.engines(context)
        Log.i(TAG, "engines: $engines")
        assumeTrue("no text-to-speech engine on this device", engines.isNotEmpty())
    }

    private fun rms(samples: FloatArray): Double = sqrt(samples.sumOf { it.toDouble() * it } / maxOf(1, samples.size))

    @Test
    fun speaksASentence() {
        AndroidSentenceVoice.open(context).use { voice ->
            Log.i(TAG, "default voice ${voice.id} at ${voice.sampleRate} Hz")
            assertTrue(voice.id.startsWith("android:"))
            assertTrue(voice.sampleRate in 8000..48000)
            val samples = voice.speak("Hello there, this is a test of speech.")
            Log.i(TAG, "${samples.size} samples, rms ${rms(samples)}")
            assertTrue("too short: ${samples.size}", samples.size > voice.sampleRate / 2)
            assertTrue("silent", rms(samples) > 0.005)
            assertTrue(samples.all { it in -1f..1f })
            assertEquals(0, voice.speak("   ").size)
            // Nothing is left behind in the cache directory.
            assertEquals(0, File(context.cacheDir, "speechwarp-voice-tts").listFiles().orEmpty().size)
        }
    }

    @Test
    fun choosesAVoiceByNameAndCarriesRateAndPitchInItsId() {
        val voices = AndroidSentenceVoice.voices(context)
        Log.i(TAG, "${voices.size} voices: ${voices.take(10)}")
        assertTrue(voices.isNotEmpty())
        val local = voices.firstOrNull { it.isInstalled && !it.requiresNetwork && it.locale.language == "en" }
            ?: voices.first { it.isInstalled && !it.requiresNetwork }
        val normal = AndroidSentenceVoice.open(context, local.name).use { voice ->
            assertEquals(local.id, voice.id)
            voice.speak("One two three four five.").size / voice.sampleRate.toDouble()
        }
        val fast = AndroidSentenceVoice.fromId(context, "android:${local.name}/2/1").use { voice ->
            assertEquals("android:${local.name}/2/1", voice.id)
            voice.speak("One two three four five.").size / voice.sampleRate.toDouble()
        }
        Log.i(TAG, "normal $normal s, at rate 2 $fast s")
        assertTrue("rate 2 took $fast s against $normal s", fast < normal * 0.8)
    }

    @Test
    fun anUnknownVoiceFails() {
        AndroidSentenceVoice(context, "no-such-voice").use { voice ->
            assertEquals("android:no-such-voice", voice.id)
            assertEquals(AndroidSentenceVoice.DEFAULT_SAMPLE_RATE, voice.sampleRate)
            try {
                voice.speak("Hello.")
                throw AssertionError("spoke with a voice that does not exist")
            } catch (e: IllegalStateException) {
                assertTrue(e.message!!.contains("no-such-voice"))
            }
        }
    }

    @Test
    fun refusesTheMainThread() {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                AndroidSentenceVoice(context).use { it.speak("Hello.") }
            } catch (e: Throwable) {
                failure = e
            }
        }
        assertTrue("main thread allowed: $failure", failure is IllegalStateException)
    }

    @Test
    fun readsATextAloudThroughTheReader() {
        val voice = AndroidSentenceVoice.open(context)
        val text = "The first sentence is short. The second one is a little longer than that. And that is all."
        VoicedText(text, voice).use { reader ->
            reader.speed = 2f
            val buffer = FloatArray(2048)
            var total = 0L
            var last = 0
            val end = System.currentTimeMillis() + 60_000
            while (!reader.isFinished) {
                assertTrue("the reader never finished: ${reader.lastError}", System.currentTimeMillis() < end)
                val frames = reader.read(buffer)
                if (frames == 0) Thread.sleep(5)
                total += frames
                assertTrue(reader.characterPosition >= last)
                last = reader.characterPosition
            }
            Log.i(TAG, "read $total frames at ${reader.sampleRate} Hz, error ${reader.lastError}")
            assertEquals(null, reader.lastError)
            assertTrue(total > reader.sampleRate)
            assertEquals(text.length, reader.characterPosition)
        }
    }

    private companion object {
        const val TAG = "AndroidSentenceVoiceTest"
    }
}
