package io.github.fredgaffey.speechwarp.voice.kokoro

import io.github.fredgaffey.speechwarp.voice.Phonemizer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

// The engine's own logic, with a stand-in for ONNX Runtime (which has no native library for this computer).
class KokoroEngineTest {
    @get:Rule
    val folder = TemporaryFolder()

    /** Records what the model is given; answers with one sample a token, or whatever [answer] says. */
    private class FakeModel(val answer: (LongArray) -> FloatArray = { FloatArray(it.size) { 0.5f } }) : KokoroEngine.Model {
        val calls = mutableListOf<LongArray>()
        val styles = mutableListOf<FloatArray>()
        var closed = false

        override fun run(ids: LongArray, style: FloatArray, speed: Float): FloatArray {
            calls.add(ids)
            styles.add(style)
            return answer(ids)
        }

        override fun close() {
            closed = true
        }
    }

    /** Leaves text as it is, so each letter is its own phoneme. */
    private object Identity : Phonemizer {
        val seen = mutableListOf<String>()
        override fun phonemize(text: String, language: String): String {
            seen.add(text)
            return text
        }
    }

    // A small vocabulary: the letters a-z are 1-26, then space and some punctuation.
    private val vocabulary: Map<Char, Long> =
        (('a'..'z').mapIndexed { i, c -> c to (i + 1).toLong() } +
            listOf(' ' to 30L, '.' to 31L, ',' to 32L, '!' to 33L, '?' to 34L, 'ɹ' to 35L)).toMap()

    private fun engine(model: FakeModel, rows: Int = 4): KokoroEngine {
        val directory = folder.newFolder()
        val voices = File(directory, "voices").apply { mkdirs() }
        // Row r of the style is filled with r, so the tests can see which row was chosen.
        val buffer = ByteBuffer.allocate(rows * 256 * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (r in 0 until rows) repeat(256) { buffer.putFloat(r.toFloat()) }
        File(voices, "af_test.bin").writeBytes(buffer.array())
        return KokoroEngine(directory, Identity, KokoroOptions(), vocabulary, model)
    }

    @Test
    fun fixesPhonemesAsKokoroJsDoes() {
        assertEquals("kˈoʊkəɹoʊ", KokoroEngine.fixPhonemes("kəkˈɔːɹoʊ", "en-us"))
        assertEquals("kˈəʊkəɹəʊ", KokoroEngine.fixPhonemes("kəkˈɔːɹəʊ", "en-gb"))
        assertEquals("ɹɛd", KokoroEngine.fixPhonemes("rɛd", "en-us"))
        assertEquals("lɔk", KokoroEngine.fixPhonemes("ɬɔx", "en-us"))
        assertEquals("tʃj", KokoroEngine.fixPhonemes("tʃʲ", "en-us"))
        assertEquals("wˈʌn hˈʌndɹɪd", KokoroEngine.fixPhonemes("wˈʌnhˈʌndɹɪd", "en-us"))
        assertEquals("ðˈɛɹz.", KokoroEngine.fixPhonemes("ðˈɛɹ z.", "en-us"))
        assertEquals("nˈaɪndi", KokoroEngine.fixPhonemes("nˈaɪnti", "en-us"))
        assertEquals("nˈaɪnti", KokoroEngine.fixPhonemes("nˈaɪnti", "en-gb"))
        assertEquals("nˈaɪntiːn", KokoroEngine.fixPhonemes("nˈaɪntiːn", "en-us"))
    }

    @Test
    fun readsTheVocabularyFromTokenizerJson() {
        val json = """{"version":"1.0","model":{"type":"x","vocab":{"${'$'}":0,";":1,"a":43,"ɑ":69,"ab":99,"\"":5}},"x":[1,2.5,true,null]}"""
        val vocab = KokoroEngine.vocabularyOf(json)
        assertEquals(mapOf('$' to 0L, ';' to 1L, 'a' to 43L, 'ɑ' to 69L, '"' to 5L), vocab)
    }

    @Test
    fun keepsPunctuationOutOfThePhonemizerAndJoinsSentences() {
        val model = FakeModel()
        val engine = engine(model)
        Identity.seen.clear()
        val audio = engine.speak("Ab, cd. Ef!", "af_test")
        assertEquals(listOf("Ab", "cd", "Ef"), Identity.seen)
        // One call: "b, cd." then a space then "f!" ("A" and "E" are not in the vocabulary, so they are left out).
        assertEquals(1, model.calls.size)
        assertArrayEquals(longArrayOf(2, 32, 30, 3, 4, 31, 30, 6, 33), model.calls[0])
        assertEquals(9, audio.size)
    }

    @Test
    fun choosesTheStyleRowByLength() {
        val model = FakeModel()
        val engine = engine(model, rows = 4)
        engine.speakPhonemes("ab", "af_test")
        engine.speakPhonemes("abcdefgh", "af_test")
        assertEquals(256, model.styles[0].size)
        assertEquals(2f, model.styles[0][0])
        assertEquals(3f, model.styles[1][255])
    }

    @Test
    fun splitsMoreThan510TokensAtPunctuation() {
        val model = FakeModel()
        val engine = engine(model)
        // 300 tokens, a comma, then 300 more: two pieces, the first ending at the comma.
        val phonemes = "a".repeat(300) + "," + "b".repeat(300)
        val audio = engine.speakPhonemes(phonemes, "af_test")
        assertEquals(listOf(301, 300), model.calls.map { it.size })
        assertEquals(32L, model.calls[0].last())
        assertEquals(601, audio.size)
    }

    @Test
    fun splitsAtASpaceWithoutPunctuationAndAnywhereWithoutEither() {
        val model = FakeModel()
        val engine = engine(model)
        engine.speakPhonemes("a".repeat(400) + " " + "b".repeat(400), "af_test")
        assertEquals(listOf(401, 400), model.calls.map { it.size })
        model.calls.clear()
        engine.speakPhonemes("c".repeat(1200), "af_test")
        assertEquals(listOf(510, 510, 180), model.calls.map { it.size })
    }

    @Test
    fun speaksAgainWithASpaceWhenTheAnswerIsNaN() {
        val model = FakeModel { ids -> if (ids.last() == 30L) FloatArray(ids.size) { 0.1f } else FloatArray(ids.size) { Float.NaN } }
        val engine = engine(model)
        val audio = engine.speakPhonemes("abc", "af_test")
        assertEquals(2, model.calls.size)
        assertArrayEquals(longArrayOf(1, 2, 3, 30), model.calls[1])
        assertTrue(audio.all { it == 0.1f })
        assertEquals(1, engine.notFiniteCount)
    }

    @Test
    fun splitsInTwoWhenASpaceDoesNotMendIt() {
        // NaN for anything longer than 7 tokens, so the 13 tokens are split after the comma near the middle.
        val model = FakeModel { ids -> FloatArray(ids.size) { if (ids.size > 7) Float.NaN else 0.2f } }
        val engine = engine(model)
        val audio = engine.speakPhonemes("abcdef,ghijkl", "af_test")
        assertEquals(13, audio.size)
        assertTrue(audio.all { it == 0.2f })
        assertArrayEquals(longArrayOf(1, 2, 3, 4, 5, 6, 32), model.calls[2])
    }

    @Test
    fun givesSilenceRatherThanNaN() {
        val model = FakeModel { ids -> FloatArray(ids.size) { Float.NaN } }
        val engine = engine(model)
        val audio = engine.speakPhonemes("abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz", "af_test")
        assertTrue(audio.isNotEmpty())
        assertTrue(audio.all { it == 0f })
    }

    @Test
    fun saysNothingForNothing() {
        val model = FakeModel()
        val engine = engine(model)
        assertEquals(0, engine.speak(" \n\n ", "af_test").size + engine.speak("", "af_test").size)
        assertEquals(0, engine.speakPhonemes("ABC", "af_test").size)
        assertTrue(model.calls.isEmpty())
    }

    @Test
    fun closesTheModel() {
        val model = FakeModel()
        engine(model).close()
        assertTrue(model.closed)
    }

    @Test(expected = java.io.FileNotFoundException::class)
    fun reportsAMissingVoice() {
        engine(FakeModel()).speak("ab", "af_missing")
    }

    @Test(expected = java.io.FileNotFoundException::class)
    fun reportsAMissingModel() {
        KokoroEngine(folder.newFolder(), Identity)
    }
}
