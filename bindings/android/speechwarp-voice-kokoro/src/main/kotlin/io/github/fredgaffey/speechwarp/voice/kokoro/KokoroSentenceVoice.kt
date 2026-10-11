package io.github.fredgaffey.speechwarp.voice.kokoro

import io.github.fredgaffey.speechwarp.voice.Phonemizer
import io.github.fredgaffey.speechwarp.voice.SentenceVoice
import java.io.File
import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode

/**
 * A Kokoro voice as a [SentenceVoice], for a live reader and a voice cache: id "kokoro:NAME", 24 kHz, and kept on
 * disk ([keepsSpoken]), because a phone speaks it little faster than it is heard.
 *
 * Each sentence goes to a [KokoroEngine] on ONNX Runtime's CPU. The engine is loaded when it is first needed, not by
 * the constructor. Several voices can share one engine (the model is the large part) through the constructor that
 * takes one.
 */
class KokoroSentenceVoice private constructor(
    private val engine: Lazy<KokoroEngine>,
    private val ownsEngine: Boolean,
    /** The model directory. */
    val directory: File,
    /** The voice's name, such as "af_heart". */
    val voice: String,
    /** The pace, 1 for the voice's own (about 0.5 to 2 work). Any other pace is part of [id]. */
    val speed: Float,
) : SentenceVoice {

    /**
     * A voice with its own engine, loaded from [directory] when first needed.
     *
     * @param directory The model directory (see [KokoroModels]).
     * @param voice The voice's name, such as "af_heart".
     * @param phonemizer Turns words into IPA, such as speechwarp-voice-espeak's EspeakPhonemizer.
     * @param options How the engine loads the model.
     * @param speed The pace, 1 for the voice's own.
     */
    @JvmOverloads
    constructor(
        directory: File,
        voice: String,
        phonemizer: Phonemizer,
        options: KokoroOptions = KokoroOptions(),
        speed: Float = 1f,
    ) : this(
        lazy(LazyThreadSafetyMode.SYNCHRONIZED) { KokoroEngine(directory, phonemizer, options) },
        true, directory, checked(voice), speed,
    )

    /**
     * A voice that speaks with [engine], which the caller keeps and closes.
     *
     * @param engine A loaded engine, perhaps shared with other voices.
     * @param voice The voice's name, such as "af_heart".
     * @param speed The pace, 1 for the voice's own.
     */
    @JvmOverloads
    constructor(engine: KokoroEngine, voice: String, speed: Float = 1f) :
        this(lazyOf(engine), false, engine.directory, checked(voice), speed)

    /**
     * "kokoro:" and the voice's name, such as "kokoro:af_heart"; at a pace other than 1, "/" and the pace follow
     * ("kokoro:af_heart/1.2"), so that audio kept at one pace is never served for another.
     */
    override val id: String = if (speed == 1f) "kokoro:$voice" else "kokoro:$voice/${formatSpeed(speed)}"

    /** 24,000 ([KokoroEngine.SAMPLE_RATE]). */
    override val sampleRate: Int get() = KokoroEngine.SAMPLE_RATE

    /** True: Kokoro on a phone is slow enough that what it speaks is worth keeping. */
    override val keepsSpoken: Boolean get() = true

    /**
     * Speaks [sentence] on ONNX Runtime.
     *
     * @return Mono samples at 24 kHz, -1 to 1; empty when there is nothing to say.
     */
    override fun speak(sentence: String): FloatArray {
        if (sentence.isBlank()) return FloatArray(0)
        return engine.value.speak(sentence, voice, speed)
    }

    /** Frees the engine if this voice loaded it; a shared engine is left to its owner. */
    override fun close() {
        if (ownsEngine && engine.isInitialized()) engine.value.close()
    }

    private companion object {
        fun checked(voice: String): String {
            KokoroModels.checkVoiceName(voice)
            return voice
        }

        /**
         * Up to three decimals, never a comma, as the C# package writes it ("0.###"): 1.2, 0.85, 1.125. Like C#, it
         * takes the float's first 7 significant digits and then rounds a half up (1.0005f, stored as 1.00049996..., is
         * "1.001"), so that the ids, and so the cache folders, agree.
         */
        fun formatSpeed(speed: Float): String =
            BigDecimal(speed.toDouble()).round(MathContext(7, RoundingMode.HALF_EVEN))
                .setScale(3, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
    }
}
