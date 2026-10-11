package io.github.fredgaffey.speechwarp.voice.kokoro

import android.os.Bundle
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.sqrt

/**
 * Kokoro on the device, with a real model. The model directory (model.onnx, tokenizer.json, voices/af_heart.bin and
 * voices/bf_emma.bin) is named by the instrumentation argument kokoroModelDir, /data/local/tmp/kokoro-model by
 * default; without a model there the tests are skipped (as on CI). For example:
 *
 * ```
 * adb push kokoro-model /data/local/tmp/
 * adb shell am instrument -w -e kokoroModelDir /data/local/tmp/kokoro-model \
 *     io.github.fredgaffey.speechwarp.voice.kokoro.test/androidx.test.runner.AndroidJUnitRunner
 * ```
 *
 * With -e kokoroCompare true, [comparesModels] also times each model and counts its NaN answers (the README's table).
 */
@RunWith(AndroidJUnit4::class)
class KokoroDeviceTest {
    private val arguments: Bundle = InstrumentationRegistry.getArguments()

    private fun modelDirectory(modelFile: String = KokoroModels.DEFAULT_MODEL_FILE): File {
        val directory = File(arguments.getString("kokoroModelDir") ?: "/data/local/tmp/kokoro-model")
        assumeTrue("No Kokoro model ($modelFile) in $directory", KokoroModels.isInstalled(directory, "af_heart", modelFile))
        return directory
    }

    /** Gives back the text, which the tests write in IPA already. */
    private object AlreadyIpa : Phonemizer {
        override fun phonemize(text: String, language: String) = text
    }

    private fun rms(samples: FloatArray) = sqrt(samples.sumOf { it.toDouble() * it } / samples.size)

    @Test
    fun speaksPhonemes() {
        KokoroEngine(modelDirectory(), AlreadyIpa).use { engine ->
            val audio = engine.speakPhonemes(HELLO, "af_heart")
            val seconds = audio.size / KokoroEngine.SAMPLE_RATE.toDouble()
            assertTrue("$seconds s", seconds in 1.2..4.5)
            assertTrue(audio.all { it.isFinite() })
            assertTrue(rms(audio) > 0.02)
        }
    }

    @Test
    fun speaksAsASentenceVoice() {
        KokoroSentenceVoice(modelDirectory(), "bf_emma", AlreadyIpa).use { voice ->
            assertEquals("kokoro:bf_emma", voice.id)
            val audio = voice.speak(HELLO)
            assertTrue(audio.size > KokoroEngine.SAMPLE_RATE)
            assertTrue(rms(audio) > 0.02)
        }
    }

    /** The NaN answers some models give for some inputs are mended or silenced: callers never see NaN. */
    @Test
    fun noLengthGivesNaN() {
        KokoroEngine(modelDirectory(), AlreadyIpa).use { engine ->
            for (length in 40..SWEEP.length step 5) {
                val voice = if (length % 2 == 0) "af_heart" else "bf_emma"
                val audio = engine.speakPhonemes(SWEEP.substring(0, length), voice)
                assertTrue("$voice, $length characters", audio.all { it.isFinite() })
                assertTrue("$voice, $length characters: speech, not silence", rms(audio) > 0.02)
            }
            Log.i(TAG, "${engine.options.modelFile}: the model gave NaN ${engine.notFiniteCount} times, mended each time")
        }
    }

    /**
     * Times each model on this device and counts the lengths for which it answers with NaN: the measurements behind
     * [KokoroModels.DEFAULT_MODEL_FILE]. Only with -e kokoroCompare true; models missing from the directory are left
     * out. The results go to logcat (tag KokoroCompare) and the instrumentation's output.
     */
    @Test
    fun comparesModels() {
        assumeTrue("Pass -e kokoroCompare true to compare the models", arguments.getString("kokoroCompare") == "true")
        val directory = modelDirectory()
        val files = (arguments.getString("kokoroModels") ?: "model.onnx,model_fp16.onnx,model_q8f16.onnx").split(',')
        val report = StringBuilder("model, xnnpack, threads: load s, NaN lengths/tried, x real time (sweep), x real time (paragraphs)\n")
        for (file in files) {
            if (!KokoroModels.isInstalled(directory, "af_heart", file)) continue
            for (xnnpack in listOf(false, true)) {
                val threadChoices = (arguments.getString("kokoroThreads") ?: "0").split(',').map { it.toInt() }
                for (threads in threadChoices) {
                    val options = KokoroOptions(modelFile = file, xnnpack = xnnpack, threads = threads)
                    val loading = System.nanoTime()
                    KokoroEngine(directory, AlreadyIpa, options).use { engine ->
                        val load = (System.nanoTime() - loading) / 1e9
                        engine.speakPhonemes(HELLO, "af_heart") // warm up
                        // Every other length of the sweep, in both voices by turns.
                        var tried = 0
                        var nan = 0
                        var frames = 0L
                        var started = System.nanoTime()
                        for (length in 20..SWEEP.length step 2) {
                            val before = engine.notFiniteCount
                            frames += engine.speakPhonemes(SWEEP.substring(0, length), if (length % 4 == 0) "af_heart" else "bf_emma").size
                            tried++
                            if (engine.notFiniteCount > before) nan++
                        }
                        val sweep = frames / KokoroEngine.SAMPLE_RATE.toDouble() / ((System.nanoTime() - started) / 1e9)
                        frames = 0
                        started = System.nanoTime()
                        for (paragraph in PARAGRAPHS) frames += engine.speakPhonemes(paragraph, "af_heart").size
                        val paragraphs = frames / KokoroEngine.SAMPLE_RATE.toDouble() / ((System.nanoTime() - started) / 1e9)
                        val line = String.format(
                            java.util.Locale.ROOT, "%s, %s, %d: %.1f s, %d/%d, %.2fx, %.2fx",
                            file, xnnpack, threads, load, nan, tried, sweep, paragraphs,
                        )
                        Log.i(TAG, line)
                        report.append(line).append('\n')
                    }
                }
            }
        }
        InstrumentationRegistry.getInstrumentation().sendStatus(0, Bundle().apply { putString("stream", report.toString()) })
    }

    private companion object {
        const val TAG = "KokoroCompare"

        /** "Hello world, this is Kokoro speaking." in eSpeak NG's American IPA, after kokoro.js's adjustments. */
        const val HELLO = "həlˈoʊ wˈɜːld, ðɪs ɪz kˈoʊkəɹoʊ spˈiːkɪŋ."

        /** The C# package's sweep of lengths. */
        const val SWEEP = "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ. ɪn nˈaɪntiːn hˈʌndɹɪd twˈɛnti fˈɔːɹ, " +
            "ðə bɹˈɪdʒ wʌz θɹˈiː hˈʌndɹɪd fˈiːt lˈɔŋ. " + HELLO

        /** Longer pieces, as a book's paragraphs are: about 15 s of speech each. */
        val PARAGRAPHS = listOf(
            "ɪt wʌz ðə bˈɛst ʌv tˈaɪmz, ɪt wʌz ðə wˈɜːst ʌv tˈaɪmz, ɪt wʌz ðɪ ˈeɪdʒ ʌv wˈɪzdəm, ɪt wʌz ðɪ ˈeɪdʒ ʌv " +
                "fˈuːlɪʃnəs, ɪt wʌz ðɪ ˈɛpək ʌv bilˈiːf, ɪt wʌz ðɪ ˈɛpək ʌv ɪnkɹɛdʒəlˈɪti. wiː hæd ˈɛvɹɪθɪŋ bɪfˈoːɹ ʌs, " +
                "wiː hæd nˈʌθɪŋ bɪfˈoːɹ ʌs.",
            "ðə sˈʌn hæd nˌɑːt jˈɛt ɹˈɪzən ˌoʊvɚ ðə hˈɪlz wɛn ðə fˈɜːst tɹˈeɪn lˈɛft ðə stˈeɪʃən. ʃiː sˈæt baɪ ðə " +
                "wˈɪndoʊ ænd wˈɑːtʃt ðə fˈiːldz ɡˈoʊ bˈaɪ, ɡɹˈeɪ æt fˈɜːst, ðˈɛn ɡɹˈiːn, ðˈɛn ɡˈoʊld ɐz ðə lˈaɪt kˈeɪm.",
            "nˈoʊbɑːdi nˈuː wˌɛɹ ðə lˈɛɾɚ hæd kˈʌm fɹʌm. ɪt hæd nˈoʊ stˈæmp, nˈoʊ ɹɪtˈɜːn ɐdɹˈɛs, ænd ðə hˈændɹaɪɾɪŋ " +
                "wʌz ˈoʊld ænd ʃˈeɪki, ɐz ɪf ðə ɹˈaɪɾɚ hæd bˌɪn ɪn ɐ ɡɹˈeɪt hˈʌɹi ɔːɹ ɐ ɡɹˈeɪt dˈiːl ʌv pˈeɪn.",
        )
    }
}
