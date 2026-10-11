package io.github.fredgaffey.speechwarp.voice.kokoro

import io.github.fredgaffey.speechwarp.voice.Phonemizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.RandomAccessFile
import java.util.Locale

class KokoroModelsTest {
    @get:Rule
    val folder = TemporaryFolder()

    @Test
    fun listsEveryFileAtTheFixedRevision() {
        assertEquals(KokoroModels.DEFAULT_MODEL_FILE, KokoroModels.models[0].file.relativePath)
        assertEquals(8, KokoroModels.models.size)
        assertEquals(54, KokoroModels.voices.size)
        assertEquals(54, KokoroModels.voices.map { it.name }.toSet().size)
        val files = KokoroModels.models.map { it.file } + KokoroModels.voices.map { it.file } + KokoroModels.tokenizer
        for (file in files) {
            assertTrue(file.url, file.url.startsWith("https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231/"))
            assertTrue(file.sha256, Regex("[0-9a-f]{64}").matches(file.sha256))
            assertTrue(file.sizeBytes > 0)
        }
        assertEquals(
            "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/1939ad2a8e416c0acfeecc08a694d14ef25f2231/onnx/model_fp16.onnx",
            KokoroModels.findModel("model_fp16")!!.file.url,
        )
        assertEquals("ba4527a874b42b21e35f468c10d326fdff3c7fc8cac1f85e9eb6c0dfc35c334a", KokoroModels.findModel("model_fp16.onnx")!!.file.sha256)
        val heart = KokoroModels.findVoice("af_heart")!!
        assertEquals("voices/af_heart.bin", heart.file.relativePath)
        assertEquals("d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b", heart.file.sha256)
        assertTrue(heart.isFemale)
        assertFalse(KokoroModels.findVoice("bm_george")!!.isFemale)
        assertNull(KokoroModels.findVoice("nobody"))
        assertNull(KokoroModels.findModel("model_huge"))
    }

    @Test
    fun knowsEachVoicesLanguage() {
        assertEquals("en-us", KokoroModels.languageOf("af_heart"))
        assertEquals("en-gb", KokoroModels.languageOf("bf_emma"))
        assertEquals("fr-fr", KokoroModels.languageOf("ff_siwis"))
        assertEquals("cmn", KokoroModels.languageOf("zf_xiaobei"))
        assertEquals("en-us", KokoroModels.languageOf(""))
        assertEquals("en-gb", KokoroModels.findVoice("bm_lewis")!!.language)
    }

    @Test
    fun saysWhatIsMissing() {
        val directory = folder.newFolder()
        assertFalse(KokoroModels.isInstalled(directory, "af_heart", "model_q8f16.onnx"))
        assertEquals(3, KokoroModels.missingFiles(directory, "af_heart", "model_q8f16.onnx").size)

        sized(File(directory, "model_q8f16.onnx"), 86_033_585L)
        sized(File(directory, "tokenizer.json"), 3497)
        sized(File(directory, "voices/af_heart.bin"), 1000) // a download that stopped part way
        assertEquals(listOf("voices/af_heart.bin"), KokoroModels.missingFiles(directory, "af_heart", "model_q8f16.onnx").map { it.relativePath })
        assertFalse(KokoroModels.isInstalled(directory, "af_heart", "model_q8f16.onnx"))

        sized(File(directory, "voices/af_heart.bin"), 522_240L)
        assertTrue(KokoroModels.missingFiles(directory, "af_heart", "model_q8f16.onnx").isEmpty())
        assertTrue(KokoroModels.isInstalled(directory, "af_heart", "model_q8f16.onnx"))
        assertFalse(KokoroModels.isInstalled(directory, "af_heart"))
        assertFalse(KokoroModels.isInstalled(directory, "../af_heart", "model_q8f16.onnx"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesAPathAsAVoiceName() {
        KokoroModels.voicePath(folder.root, "../secret")
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesAVoiceNotInTheCatalogue() {
        KokoroModels.missingFiles(folder.root, "af_nobody")
    }

    @Test
    fun namesTheVoiceAndItsPace() {
        val nothing = object : Phonemizer {
            override fun phonemize(text: String, language: String) = throw AssertionError("not used")
        }
        val directory = folder.newFolder()
        val default = Locale.getDefault()
        Locale.setDefault(Locale.GERMANY) // a decimal comma, which an id must never have
        try {
            KokoroSentenceVoice(directory, "af_heart", nothing).use { voice ->
                assertEquals("kokoro:af_heart", voice.id)
                assertEquals(24000, voice.sampleRate)
                assertTrue(voice.keepsSpoken)
                // Nothing to say needs no model, and the engine is not loaded until it is needed.
                assertEquals(0, voice.speak("  ").size)
            }
            assertEquals("kokoro:bf_emma/1.2", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 1.2f).id)
            assertEquals("kokoro:bf_emma/0.85", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 0.85f).id)
            assertEquals("kokoro:bf_emma/1.125", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 1.125f).id)
            assertEquals("kokoro:bf_emma/2", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 2f).id)
            // Rounded as C# rounds "0.###": a half up, from the float's first 7 digits.
            assertEquals("kokoro:bf_emma/1.063", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 1.0625f).id)
            assertEquals("kokoro:bf_emma/1.001", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 1.0005f).id)
            assertEquals("kokoro:bf_emma/1.235", KokoroSentenceVoice(directory, "bf_emma", nothing, speed = 1.23456f).id)
        } finally {
            Locale.setDefault(default)
        }
        assertNotNull(KokoroOptions())
    }

    @Test(expected = IllegalArgumentException::class)
    fun refusesABadVoiceNameAtOnce() {
        KokoroSentenceVoice(folder.root, "af heart", object : Phonemizer {
            override fun phonemize(text: String, language: String) = text
        })
    }

    private fun sized(file: File, size: Long) {
        file.parentFile!!.mkdirs()
        RandomAccessFile(file, "rw").use { it.setLength(size) }
    }
}
