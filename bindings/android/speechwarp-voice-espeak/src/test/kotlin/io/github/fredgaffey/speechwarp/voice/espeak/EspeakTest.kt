package io.github.fredgaffey.speechwarp.voice.espeak

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// eSpeak on this computer's JVM, against the host build of the JNI library and the data the build compiled.
class EspeakTest {
    companion object {
        @BeforeClass
        @JvmStatic
        fun useTheCompiledData() {
            if (Espeak.dataPath == null) Espeak.dataPath = File(System.getProperty("speechwarp.espeak.data")!!)
        }
    }

    @Test
    fun speaks() {
        assertEquals(22050, Espeak.sampleRate)
        val samples = Espeak.speak("The quick brown fox jumps over the lazy dog.", "en-us")
        // About two and a half seconds at 175 words a minute.
        assertTrue("${samples.size} samples", samples.size in 22050 * 3 / 2..22050 * 5)
        assertTrue(samples.all { it.isFinite() && it >= -1f && it <= 1f })
        assertTrue(samples.maxOf { Math.abs(it) } > 0.05f)
        assertEquals(0, Espeak.speak("   ", "en-us").size)
    }

    @Test
    fun speaksFasterAtAHigherRate() {
        val slow = Espeak.speak("The quick brown fox jumps over the lazy dog.", "en-gb", 120)
        val fast = Espeak.speak("The quick brown fox jumps over the lazy dog.", "en-gb", 350)
        assertTrue("${slow.size} then ${fast.size}", fast.size < slow.size * 0.6)
    }

    @Test
    fun makesIpa() {
        assertEquals("ðə kwˈɪk bɹˈaʊn fˈɑːks", Espeak.phonemes("The quick brown fox", "en-us"))
        // Received Pronunciation drops the r and has another vowel in "fox".
        val british = Espeak.phonemes("The quick brown fox", "en-gb")
        assertTrue(british, british.endsWith("fˈɒks"))
        // Clauses are separated by a space.
        assertEquals("həlˈoʊ wˈɜːld", Espeak.phonemes("Hello, world", "en-us"))
    }

    @Test
    fun findsVoicesByLanguageAndKeepsTheVariant() {
        // "en-gb" names no file in eSpeak's data (it is lang/gmw/en), so it is found by language.
        assertTrue(Espeak.speak("Hello.", "en-gb").isNotEmpty())
        assertTrue(Espeak.speak("Hello.", "en-gb+klatt").isNotEmpty())
        assertTrue(Espeak.speak("Hello.", "en-gb-x-rp").isNotEmpty())
        assertTrue(Espeak.phonemes("Hello", "en-029").isNotEmpty())
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesAnUnknownLanguage() {
        Espeak.speak("Hello.", "xx-nowhere")
    }

    @Test
    fun listsVoicesAndVariants() {
        val voices = Espeak.voices
        val british = voices.single { it.identifier == "gmw/en" }
        assertEquals("en-gb", british.language)
        assertTrue(british.languages.contains("en"))
        assertTrue(voices.any { it.language == "en-us" })
        assertTrue(Espeak.variants.contains("klatt"))
        assertEquals("1.52.0", Espeak.version)
    }

    @Test
    fun namesTheSentenceVoice() {
        val voice = EspeakSentenceVoice("en-gb")
        assertEquals("espeak:en-gb", voice.id)
        assertEquals(22050, voice.sampleRate)
        assertEquals(false, voice.keepsSpoken)
        assertEquals("espeak:en-gb/220/50", EspeakSentenceVoice("en-gb", 220).id)
        assertEquals("espeak:en-us/175/40", EspeakSentenceVoice("en-us", pitch = 40).id)
        assertTrue(voice.speak("A sentence.").isNotEmpty())
        assertEquals("ðə kwˈɪk bɹˈaʊn fˈɑːks", EspeakPhonemizer().phonemize("The quick brown fox", "en-us"))
    }

    @Test
    fun takesTurnsAcrossThreads() {
        val pool = Executors.newFixedThreadPool(4)
        val results = (0 until 16).map { i ->
            pool.submit<String> { if (i % 2 == 0) Espeak.phonemes("The quick brown fox", "en-us") else Espeak.speak("Hello there.", "en-gb").size.toString() }
        }.map { it.get(60, TimeUnit.SECONDS) }
        pool.shutdown()
        assertTrue(results.filterIndexed { i, _ -> i % 2 == 0 }.all { it == "ðə kwˈɪk bɹˈaʊn fˈɑːks" })
        // eSpeak varies its timing by a few samples from one call to the next, on purpose.
        val lengths = results.filterIndexed { i, _ -> i % 2 == 1 }.map { it.toInt() }
        assertTrue(lengths.toString(), lengths.max() - lengths.min() < lengths.min() / 100)
    }
}
