package io.github.fredgaffey.speechwarp.voice.kokoro

import io.github.fredgaffey.speechwarp.voice.Phonemizer
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * What [KokoroBenchmark.run] measured.
 *
 * @property engines How many engines spoke at once.
 * @property paragraphs Paragraphs spoken.
 * @property audioSeconds Seconds of audio produced.
 * @property elapsedSeconds Seconds it took, after loading.
 * @property loadSeconds Seconds the first engine took to load the model.
 * @property notFinite How many times the model answered with NaN and was run again (see [KokoroEngine]).
 */
data class KokoroBenchmarkResult(
    val engines: Int,
    val paragraphs: Int,
    val audioSeconds: Double,
    val elapsedSeconds: Double,
    val loadSeconds: Double,
    val notFinite: Int,
) {
    /** Seconds of work for each second of audio: below 1 is faster than listening. */
    val realTimeFactor: Double get() = if (audioSeconds > 0) elapsedSeconds / audioSeconds else Double.POSITIVE_INFINITY

    /** Seconds of audio for each second of work, the inverse: above 1 is faster than listening. */
    val timesRealTime: Double get() = if (elapsedSeconds > 0) audioSeconds / elapsedSeconds else 0.0
}

/**
 * How fast Kokoro speaks on this device: speaks paragraphs of a text for a while and measures the audio produced.
 * Nothing is played. Run it on the device that matters, off the main thread (it takes up to [run]'s duration).
 */
object KokoroBenchmark {
    /**
     * Speaks the paragraphs of [text] (separated by blank lines), in order, until they run out or [durationSeconds]
     * have passed, with [parallel] engines speaking different paragraphs at once (to see whether running several
     * helps).
     *
     * @param directory The model directory.
     * @param phonemizer Turns words into IPA; it must be safe to call from several threads if parallel is above 1.
     * @param text What to speak.
     * @param voice The voice, [KokoroModels.DEFAULT_VOICE] unless given.
     * @param options How each engine loads the model.
     * @param durationSeconds How long to keep going: 60 s unless given. A paragraph under way is finished.
     * @param parallel Engines speaking at once, 1 or more.
     */
    @JvmStatic
    @JvmOverloads
    fun run(
        directory: File,
        phonemizer: Phonemizer,
        text: String,
        voice: String = KokoroModels.DEFAULT_VOICE,
        options: KokoroOptions = KokoroOptions(),
        durationSeconds: Double = 60.0,
        parallel: Int = 1,
    ): KokoroBenchmarkResult {
        require(parallel >= 1) { "parallel must be 1 or more." }
        val paragraphs = text.split("\r\n\r\n", "\n\n").map { it.trim() }.filter { it.isNotEmpty() }
        val limitNanos = (durationSeconds * 1e9).toLong()

        val loading = System.nanoTime()
        val engines = mutableListOf(KokoroEngine(directory, phonemizer, options))
        val load = (System.nanoTime() - loading) / 1e9
        val pool = Executors.newFixedThreadPool(parallel)
        try {
            repeat(parallel - 1) { engines.add(KokoroEngine(directory, phonemizer, options)) }
            val next = AtomicInteger(-1)
            val spoken = AtomicInteger()
            val frames = AtomicLong()
            val started = System.nanoTime()
            val workers = engines.map { engine ->
                pool.submit(Callable {
                    while (System.nanoTime() - started < limitNanos) {
                        val i = next.incrementAndGet()
                        if (i >= paragraphs.size) break
                        frames.addAndGet(engine.speak(paragraphs[i], voice).size.toLong())
                        spoken.incrementAndGet()
                    }
                })
            }
            try {
                workers.forEach { it.get() }
            } catch (e: ExecutionException) {
                throw e.cause ?: e
            }
            return KokoroBenchmarkResult(
                parallel, spoken.get(), frames.get() / KokoroEngine.SAMPLE_RATE.toDouble(),
                (System.nanoTime() - started) / 1e9, load, engines.sumOf { it.notFiniteCount },
            )
        } finally {
            pool.shutdownNow()
            engines.forEach { it.close() }
        }
    }
}
