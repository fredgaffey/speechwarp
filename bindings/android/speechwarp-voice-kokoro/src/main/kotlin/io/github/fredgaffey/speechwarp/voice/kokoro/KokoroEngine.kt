package io.github.fredgaffey.speechwarp.voice.kokoro

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import io.github.fredgaffey.speechwarp.voice.Phonemizer
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Kokoro-82M, a small neural text-to-speech model (af_heart and the other voices), run with ONNX Runtime on the CPU.
 * Text goes to phonemes (IPA) through a [Phonemizer], as kokoro.js and kokoro-onnx do with eSpeak NG, then through
 * the model with the voice's style. 24 kHz mono.
 *
 * The model directory holds the model (model.onnx or another of [KokoroModels.models]), tokenizer.json and
 * voices/NAME.bin; [KokoroModels] lists where to download them.
 *
 * Punctuation is kept out of the phonemizer and given to the model as it is, for its phrasing; the phonemes are then
 * adjusted as kokoro.js does. Text longer than the model's 510 tokens is spoken in pieces, split between sentences
 * where it can be.
 *
 * Thread safety: [speak] and [speakPhonemes] may be called from several threads at once (ONNX Runtime runs sessions
 * concurrently, and the voice cache is shared safely) provided the phonemizer is itself safe to call from several
 * threads. Loading the model takes a second or more and about the model's size in memory, so share one engine
 * between voices rather than making one per voice. [close] must not overlap a call.
 */
class KokoroEngine internal constructor(
    /** The model directory given to the constructor. */
    val directory: File,
    private val phonemizer: Phonemizer,
    /** The options the model was loaded with. */
    val options: KokoroOptions,
    private val vocabulary: Map<Char, Long>,
    private val model: Model,
) : AutoCloseable {

    /**
     * Loads the model in [directory].
     *
     * @param directory Holds the model, tokenizer.json and voices/NAME.bin (see [KokoroModels]).
     * @param phonemizer Turns runs of words into IPA, such as speechwarp-voice-espeak's EspeakPhonemizer.
     * @param options The model file and threads.
     * @throws FileNotFoundException The model or tokenizer.json is not in the directory.
     * @throws ai.onnxruntime.OrtException ONNX Runtime could not load the model.
     */
    @JvmOverloads
    constructor(directory: File, phonemizer: Phonemizer, options: KokoroOptions = KokoroOptions()) :
        this(directory, phonemizer, options, readVocabulary(directory, options), OnnxModel(KokoroModels.modelPath(directory, options.modelFile), options))

    /** What runs the model: ONNX Runtime, or a stand-in in the unit tests. */
    internal interface Model : AutoCloseable {
        /** The model's audio for [ids] (without the padding) in the style row [style], at [speed]. */
        fun run(ids: LongArray, style: FloatArray, speed: Float): FloatArray
    }

    private val space: Long = vocabulary[' '] ?: -1
    private val breaks: Set<Long> = ".,;:!?—…".mapNotNull { vocabulary[it] }.toSet()
    private val voices = ConcurrentHashMap<String, FloatArray>()
    private val notFinite = AtomicInteger()

    @Volatile
    private var closed = false

    /** How many times the model has answered with NaN and been run again (for tests and diagnostics). */
    val notFiniteCount: Int get() = notFinite.get()

    /**
     * Speaks [text] (a sentence or a few) in [voice], such as "af_heart", at [speed] (1 is the voice's own pace;
     * about 0.5 to 2 work).
     *
     * @return Mono samples at [SAMPLE_RATE], -1 to 1; empty when there is nothing to say.
     * @throws FileNotFoundException The voice's file is not in the voices folder.
     */
    @JvmOverloads
    fun speak(text: String, voice: String, speed: Float = 1f): FloatArray {
        check(!closed) { "The engine is closed." }
        val style = voice(voice)
        val language = KokoroModels.languageOf(voice)
        val tokens = ArrayList<Long>()
        val audio = Samples()
        for (sentence in SENTENCE_END.split(text)) {
            val trimmed = sentence.trim()
            if (trimmed.isEmpty()) continue
            val ids = tokenize(phonemize(trimmed, language))
            if (ids.isEmpty()) continue
            // Sentences go to the model together, for their phrasing, while they fit.
            if (tokens.isNotEmpty() && tokens.size + 1 + ids.size > MAX_TOKENS) {
                runAll(tokens, style, speed, audio)
                tokens.clear()
            }
            if (tokens.isNotEmpty() && space >= 0) tokens.add(space)
            tokens.addAll(ids)
        }
        runAll(tokens, style, speed, audio)
        return audio.toArray()
    }

    /**
     * Speaks [phonemes], IPA as [phonemize] returns it, in [voice], for callers that make phonemes some other way.
     * Characters the model does not know are left out.
     *
     * @return Mono samples at [SAMPLE_RATE], -1 to 1; empty when there is nothing to say.
     */
    @JvmOverloads
    fun speakPhonemes(phonemes: String, voice: String, speed: Float = 1f): FloatArray {
        check(!closed) { "The engine is closed." }
        val style = voice(voice)
        val audio = Samples()
        runAll(tokenize(phonemes), style, speed, audio)
        return audio.toArray()
    }

    /**
     * The phonemes the model is given for [text]: the phonemizer's IPA between the punctuation, which is kept,
     * adjusted as kokoro.js does.
     *
     * @param text Text in [language].
     * @param language "en-us", "en-gb" or another of [KokoroModels.languageOf]'s answers.
     */
    fun phonemize(text: String, language: String): String {
        val result = StringBuilder()
        var last = 0
        for (punctuation in PUNCTUATION.findAll(text)) {
            val start = punctuation.range.first
            if (start > last) result.append(phonemizer.phonemize(text.substring(last, start), language))
            result.append(punctuation.value)
            last = punctuation.range.last + 1
        }
        if (last < text.length) result.append(phonemizer.phonemize(text.substring(last), language))
        return fixPhonemes(result.toString(), language)
    }

    /** The model's token ids for [phonemes]; characters it does not know are left out. */
    internal fun tokenize(phonemes: String): List<Long> = phonemes.mapNotNull { vocabulary[it] }

    /** Runs the model on [tokens], in pieces of at most [MAX_TOKENS]. */
    private fun runAll(tokens: List<Long>, style: FloatArray, speed: Float, audio: Samples) {
        var start = 0
        while (start < tokens.size) {
            val count = pieceLength(tokens, start)
            audio.add(runFinite(tokens.subList(start, start + count), style, speed, 0))
            start += count
        }
    }

    /**
     * Runs the model, and when its answer is not all numbers runs it again differently: the half-precision model
     * (model_fp16) on ONNX Runtime's CPU gives NaN for the whole of some inputs, depending on the exact tokens. A
     * space added at the end mends most; the rest are split in two near the middle, at punctuation or a space.
     * Whatever still fails is returned as silence, so callers never get NaN.
     */
    private fun runFinite(ids: List<Long>, style: FloatArray, speed: Float, depth: Int): FloatArray {
        var audio = run(ids, style, speed)
        if (isFinite(audio)) return audio
        notFinite.incrementAndGet()
        if (space >= 0 && (ids.isEmpty() || ids.last() != space) && ids.size < MAX_TOKENS) {
            audio = run(ids + space, style, speed)
            if (isFinite(audio)) return audio
        }
        val middle = if (depth < 4) splitPoint(ids) else -1
        if (middle > 0) {
            val first = runFinite(ids.subList(0, middle), style, speed, depth + 1)
            val second = runFinite(ids.subList(middle, ids.size), style, speed, depth + 1)
            return first + second
        }
        for (i in audio.indices) {
            if (!audio[i].isFinite()) audio[i] = 0f
        }
        return audio
    }

    private fun isFinite(audio: FloatArray): Boolean = audio.all { it.isFinite() }

    /**
     * Where to cut [ids] in two: after the punctuation nearest the middle, or failing that the space nearest it; -1
     * when there is neither, or the run is too short to be worth cutting.
     */
    private fun splitPoint(ids: List<Long>): Int {
        if (ids.size < 8) return -1
        val half = ids.size / 2
        var best = -1
        var bestSpace = -1
        for (i in 2 until ids.size - 2) {
            val distance = Math.abs(i - half)
            if (ids[i] in breaks && (best < 0 || distance < Math.abs(best - half))) best = i
            if (ids[i] == space && (bestSpace < 0 || distance < Math.abs(bestSpace - half))) bestSpace = i
        }
        val cut = if (best >= 0) best else bestSpace
        return if (cut >= 0) cut + 1 else -1
    }

    /**
     * How many tokens from [start] go to the model together: all that are left if they fit, or else up to the last
     * punctuation, or failing that the last space, within [MAX_TOKENS].
     */
    internal fun pieceLength(tokens: List<Long>, start: Int): Int {
        val left = tokens.size - start
        if (left <= MAX_TOKENS) return left
        var lastPunctuation = -1
        var lastSpace = -1
        var i = start + MAX_TOKENS - 1
        while (i > start) {
            if (lastPunctuation < 0 && tokens[i] in breaks) lastPunctuation = i
            if (lastSpace < 0 && tokens[i] == space) lastSpace = i
            if (lastPunctuation >= 0) break
            i--
        }
        val end = if (lastPunctuation >= 0) lastPunctuation else lastSpace
        return if (end > start) end - start + 1 else MAX_TOKENS
    }

    private fun run(ids: List<Long>, style: FloatArray, speed: Float): FloatArray {
        check(!closed) { "The engine is closed." }
        if (ids.isEmpty()) return FloatArray(0)
        // The style row is chosen by the length.
        val rows = style.size / STYLE_SIZE
        val row = minOf(ids.size, rows - 1)
        return model.run(ids.toLongArray(), style.copyOfRange(row * STYLE_SIZE, (row + 1) * STYLE_SIZE), speed)
    }

    /** The style vectors of [name], read from voices/NAME.bin the first time. */
    private fun voice(name: String): FloatArray {
        KokoroModels.checkVoiceName(name)
        voices[name]?.let { return it }
        val path = KokoroModels.voicePath(directory, name)
        if (!path.isFile) throw FileNotFoundException("Kokoro's voice $name is not in the voices folder: $path")
        val bytes = path.readBytes()
        if (bytes.size < STYLE_SIZE * 4 || bytes.size % (STYLE_SIZE * 4) != 0) {
            throw IOException("$path is not a Kokoro voice file (rows of $STYLE_SIZE floats).")
        }
        val floats = FloatArray(bytes.size / 4)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floats)
        return voices.putIfAbsent(name, floats) ?: floats
    }

    /** Frees the model. The engine cannot be used afterwards. */
    override fun close() {
        if (closed) return
        closed = true
        model.close()
    }

    companion object {
        /** Frames a second of what the engine returns: 24,000. Mono. */
        const val SAMPLE_RATE = 24000

        /** The most phoneme tokens the model takes at once. */
        const val MAX_TOKENS = 510

        private const val STYLE_SIZE = 256

        private val SENTENCE_END = Regex("""(?<=[.!?…])\s+|\n{2,}""")
        private val PUNCTUATION = Regex("""(\s*[;:,.!?¡¿—…"«»“”(){}\[\]]+\s*)+""")
        private val HUNDRED = Regex("""(?<=[a-zɹː])(?=hˈʌndɹɪd)""")
        private val LONE_Z = Regex(""" z(?=[;:,.!?¡¿—…"«»“” ]|$)""")
        private val NINETY = Regex("""(?<=nˈaɪn)ti(?!ː)""")

        /** kokoro.js's adjustments to eSpeak's IPA, for the phonemes Kokoro was trained on. */
        internal fun fixPhonemes(phonemes: String, language: String): String {
            var ps = phonemes
                .replace("kəkˈoːɹoʊ", "kˈoʊkəɹoʊ")
                .replace("kəkˈɔːɹoʊ", "kˈoʊkəɹoʊ") // eSpeak NG 1.52's American "Kokoro"
                .replace("kəkˈɔːɹəʊ", "kˈəʊkəɹəʊ")
                .replace("ʲ", "j")
                .replace("r", "ɹ")
                .replace("x", "k")
                .replace("ɬ", "l")
            ps = HUNDRED.replace(ps, " ")
            ps = LONE_Z.replace(ps, "z")
            if (language == "en-us") ps = NINETY.replace(ps, "di")
            return ps.trim()
        }

        /** The model's vocabulary, after checking that the model and tokenizer.json are both there. */
        private fun readVocabulary(directory: File, options: KokoroOptions): Map<Char, Long> {
            val modelPath = KokoroModels.modelPath(directory, options.modelFile)
            val tokenizerPath = KokoroModels.tokenizerPath(directory)
            if (!modelPath.isFile) throw FileNotFoundException("Kokoro's model is not in the model directory: $modelPath")
            if (!tokenizerPath.isFile) throw FileNotFoundException("Kokoro's tokenizer.json is not in the model directory: $tokenizerPath")
            return vocabularyOf(tokenizerPath.readText())
        }

        /** The single characters of tokenizer.json's model.vocab and their ids. */
        internal fun vocabularyOf(tokenizerJson: String): Map<Char, Long> {
            val root = Json(tokenizerJson).parse() as? Map<*, *> ?: throw IOException("tokenizer.json is not a JSON object.")
            val model = root["model"] as? Map<*, *> ?: throw IOException("tokenizer.json has no model.")
            val vocab = model["vocab"] as? Map<*, *> ?: throw IOException("tokenizer.json has no model.vocab.")
            val result = HashMap<Char, Long>()
            for ((key, value) in vocab) {
                if (key is String && key.length == 1 && value is Number) result[key[0]] = value.toLong()
            }
            return result
        }
    }
}

/** Kokoro on ONNX Runtime's CPU. */
internal class OnnxModel(path: File, options: KokoroOptions) : KokoroEngine.Model {
    private val environment: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession

    init {
        val threads = if (options.threads > 0) options.threads else defaultThreads()
        session = OrtSession.SessionOptions().use { sessionOptions ->
            sessionOptions.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            if (options.xnnpack) {
                // XNNPACK has a thread pool of its own; ONNX Runtime's is then best kept to one thread and not
                // spinning, as its documentation advises.
                sessionOptions.setIntraOpNumThreads(1)
                sessionOptions.addConfigEntry("session.intra_op.allow_spinning", "0")
                sessionOptions.addXnnpack(mapOf("intra_op_num_threads" to threads.toString()))
            } else {
                sessionOptions.setIntraOpNumThreads(threads)
            }
            environment.createSession(path.path, sessionOptions)
        }
    }

    override fun run(ids: LongArray, style: FloatArray, speed: Float): FloatArray {
        // The model expects the ids between two padding tokens (0).
        val padded = LongArray(ids.size + 2)
        ids.copyInto(padded, 1)
        OnnxTensor.createTensor(environment, LongBuffer.wrap(padded), longArrayOf(1, padded.size.toLong())).use { input ->
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(style), longArrayOf(1, style.size.toLong())).use { styleTensor ->
                OnnxTensor.createTensor(environment, FloatBuffer.wrap(floatArrayOf(speed)), longArrayOf(1)).use { speedTensor ->
                    session.run(mapOf("input_ids" to input, "style" to styleTensor, "speed" to speedTensor)).use { results ->
                        val buffer = (results.get(0) as OnnxTensor).floatBuffer
                        return FloatArray(buffer.remaining()).also { buffer.get(it) }
                    }
                }
            }
        }
    }

    override fun close() = session.close()

    private companion object {
        /**
         * One thread a core, at most four: a phone's other cores are small ones, and a sentence split across them
         * waits for the slowest.
         */
        fun defaultThreads(): Int = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
    }
}

/** A growing array of samples. */
private class Samples {
    private var data = FloatArray(0)
    private var size = 0

    fun add(samples: FloatArray) {
        if (size + samples.size > data.size) data = data.copyOf(maxOf(size + samples.size, data.size * 2))
        samples.copyInto(data, size)
        size += samples.size
    }

    fun toArray(): FloatArray = data.copyOf(size)
}

/** Just enough JSON to read tokenizer.json: objects, arrays, strings, numbers, true, false and null. */
internal class Json(private val text: String) {
    private var at = 0

    fun parse(): Any? {
        val value = value()
        space()
        if (at != text.length) fail("text after the end")
        return value
    }

    private fun value(): Any? {
        space()
        if (at >= text.length) fail("the end of the text")
        return when (val c = text[at]) {
            '{' -> obj()
            '[' -> array()
            '"' -> string()
            't' -> word("true", true)
            'f' -> word("false", false)
            'n' -> word("null", null)
            else -> if (c == '-' || c in '0'..'9') number() else fail("'$c'")
        }
    }

    private fun obj(): Map<String, Any?> {
        at++
        val result = LinkedHashMap<String, Any?>()
        space()
        if (peek() == '}') { at++; return result }
        while (true) {
            space()
            if (peek() != '"') fail("a key expected")
            val key = string()
            space()
            if (peek() != ':') fail("':' expected")
            at++
            result[key] = value()
            space()
            when (peek()) {
                ',' -> at++
                '}' -> { at++; return result }
                else -> fail("',' or '}' expected")
            }
        }
    }

    private fun array(): List<Any?> {
        at++
        val result = ArrayList<Any?>()
        space()
        if (peek() == ']') { at++; return result }
        while (true) {
            result.add(value())
            space()
            when (peek()) {
                ',' -> at++
                ']' -> { at++; return result }
                else -> fail("',' or ']' expected")
            }
        }
    }

    private fun string(): String {
        at++
        val result = StringBuilder()
        while (true) {
            if (at >= text.length) fail("an unfinished string")
            val c = text[at++]
            when (c) {
                '"' -> return result.toString()
                '\\' -> {
                    if (at >= text.length) fail("an unfinished string")
                    when (val e = text[at++]) {
                        '"', '\\', '/' -> result.append(e)
                        'b' -> result.append('\b')
                        'f' -> result.append('\u000C')
                        'n' -> result.append('\n')
                        'r' -> result.append('\r')
                        't' -> result.append('\t')
                        'u' -> {
                            if (at + 4 > text.length) fail("an unfinished escape")
                            result.append(text.substring(at, at + 4).toInt(16).toChar())
                            at += 4
                        }
                        else -> fail("the escape \\$e")
                    }
                }
                else -> result.append(c)
            }
        }
    }

    private fun number(): Number {
        val start = at
        while (at < text.length && (text[at] in "+-.eE" || text[at] in '0'..'9')) at++
        val s = text.substring(start, at)
        return s.toLongOrNull() ?: s.toDoubleOrNull() ?: fail("the number $s")
    }

    private fun word(word: String, value: Any?): Any? {
        if (!text.startsWith(word, at)) fail("'${text[at]}'")
        at += word.length
        return value
    }

    private fun peek(): Char = if (at < text.length) text[at] else '\u0000'

    private fun space() {
        while (at < text.length && text[at].isWhitespace()) at++
    }

    private fun fail(what: String): Nothing = throw IOException("tokenizer.json is not valid JSON: $what at $at.")
}
