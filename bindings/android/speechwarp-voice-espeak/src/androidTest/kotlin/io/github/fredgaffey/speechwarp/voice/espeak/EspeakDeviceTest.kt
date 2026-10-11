package io.github.fredgaffey.speechwarp.voice.espeak

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroEngine
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroModels
import io.github.fredgaffey.speechwarp.voice.kokoro.KokoroSentenceVoice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.sqrt

/**
 * eSpeak on the device, with its data copied from the assets; and Kokoro speaking with eSpeak's phonemes, when a
 * Kokoro model is in the directory named by the instrumentation argument kokoroModelDir
 * (/data/local/tmp/kokoro-model by default; skipped without one, as on CI).
 */
@RunWith(AndroidJUnit4::class)
class EspeakDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Before
    fun putTheDataInPlace() {
        Espeak.initialize(context)
    }

    private fun rms(samples: FloatArray) = sqrt(samples.sumOf { it.toDouble() * it } / samples.size)

    @Test
    fun copiesTheDataToTheFilesFolder() {
        val data = Espeak.initialize(context)
        assertEquals(File(context.filesDir, "speechwarp-espeak/espeak-ng-data"), data)
        assertEquals(data, Espeak.dataPath)
        assertTrue(File(data, "en_dict").length() > 100_000)
        assertTrue(File(data, "phondata").isFile)
        // The variants' folder is named "!v"; it must survive the app's packaging.
        assertTrue(Espeak.variants.toString(), Espeak.variants.contains("klatt"))
        assertEquals("1.52.0", Espeak.version)
    }

    @Test
    fun makesIpa() {
        assertEquals("ðə kwˈɪk bɹˈaʊn fˈɑːks", EspeakPhonemizer(context).phonemize("The quick brown fox", "en-us"))
        assertTrue(Espeak.phonemes("The quick brown fox", "en-gb").endsWith("fˈɒks"))
    }

    @Test
    fun speaks() {
        val voice = EspeakSentenceVoice(context, "en-gb")
        assertEquals("espeak:en-gb", voice.id)
        assertEquals(22050, voice.sampleRate)
        val samples = voice.speak("The quick brown fox jumps over the lazy dog.")
        assertTrue("${samples.size} samples", samples.size in 22050 * 3 / 2..22050 * 5)
        assertTrue(samples.all { it.isFinite() && it in -1f..1f })
        assertTrue(rms(samples) > 0.01)
        assertTrue(EspeakSentenceVoice(context, "en-us+klatt", 300, 70).speak("Hello there.").isNotEmpty())
        assertTrue(Espeak.voices.any { it.identifier == "gmw/en" && it.language == "en-gb" })
    }

    @Test
    fun kokoroSpeaksWithEspeaksPhonemes() {
        val directory = File(InstrumentationRegistry.getArguments().getString("kokoroModelDir") ?: "/data/local/tmp/kokoro-model")
        assumeTrue("No Kokoro model in $directory", KokoroModels.isInstalled(directory, "af_heart"))
        KokoroEngine(directory, EspeakPhonemizer(context)).use { engine ->
            assertEquals("ðə kwˈɪk bɹˈaʊn fˈɑːks.", engine.phonemize("The quick brown fox.", "en-us"))
            KokoroSentenceVoice(engine, "af_heart").use { voice ->
                val audio = voice.speak("The quick brown fox jumps over the lazy dog.")
                val seconds = audio.size / KokoroEngine.SAMPLE_RATE.toDouble()
                assertTrue("$seconds s", seconds in 1.5..5.0)
                assertTrue(audio.all { it.isFinite() })
                assertTrue(rms(audio) > 0.02)
            }
        }
    }
}
