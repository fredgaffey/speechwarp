package io.github.fredgaffey.speechwarp.voice

import io.github.fredgaffey.speechwarp.SpeechwarpStream
import java.io.File
import java.util.Collections
import java.util.IdentityHashMap
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToLong

/** Makes a voice from its id, for [VoicedText.setVoice]. Called on the reader's own thread. */
fun interface VoiceFactory {
    fun create(voiceId: String): SentenceVoice
}

/**
 * How a [VoicedText] reads: its output, how far ahead it speaks, and where it keeps what slow voices say.
 *
 * @property sampleRate the sample rate of what [VoicedText.read] returns. Default (null): the first voice's. Voices
 * that speak at another rate are converted to it.
 * @property speedUp whether the audio goes through a [SpeechwarpStream], so that [VoicedText.speed] and
 * [VoicedText.configure] work. False gives the voices' audio as spoken, for a player that speeds it up itself.
 * @property lookahead seconds of listening to keep spoken ahead of what is being read, for a fast voice.
 * @property keptLookahead seconds of listening to keep spoken ahead for a slow voice ([SentenceVoice.keepsSpoken]),
 * which needs longer to catch up after a pause.
 * @property secondsPerCharacter the pace of the timeline: a character of the text is this many seconds long, whatever
 * the voice, so that a place ([VoicedText.timeAt], [VoicedText.seekToTime]) is the same character in every voice.
 * Default 1/17, about the pace of ordinary synthetic speech.
 * @property cacheDirectory where a slow voice's sentences are kept (see [VoiceCache];
 * [VoiceCache.defaultDirectory] is the usual place). Null keeps nothing on disk.
 * @property speakAheadToDisk asked when everything within the lookahead is spoken: true lets a slow voice carry on
 * speaking whole blocks into the cache beyond it (an app might say true while the device is charging). Needs
 * [cacheDirectory]. Called on the reader's thread. Null: never.
 * @property locale the language whose rules cut the text into sentences. Null: the device's.
 */
data class VoicedTextOptions @JvmOverloads constructor(
    val sampleRate: Int? = null,
    val speedUp: Boolean = true,
    val lookahead: Double = 30.0,
    val keptLookahead: Double = 120.0,
    val secondsPerCharacter: Double = 1 / 17.0,
    val cacheDirectory: File? = null,
    val speakAheadToDisk: (() -> Boolean)? = null,
    val locale: Locale? = null,
)

/**
 * A text read aloud by any [SentenceVoice] (Android's voices, Kokoro, eSpeak NG ...), sentence by sentence, spoken on
 * a thread of its own ahead of what is being read, optionally sped up by speechwarp. The voice can change between
 * sentences.
 *
 * ```
 * val book = VoicedText(text, voice)               // made off the main thread if the voice blocks to start
 * book.speed = 3f
 * book.configure { it.setHeardPause(0.03f, 3f) }
 * // on the audio thread:
 * val frames = book.read(buffer)                   // mono, book.sampleRate; never waits
 * // for the display:
 * val at = book.characterPosition                  // index into the text
 * // from the next sentence on, another voice:
 * book.setVoice(otherVoice)
 * ```
 *
 * Sentences are spoken on the reader's own background thread, one at a time, until [lookahead] seconds of listening
 * are ready ([keptLookahead] for a slow voice). [read] never waits: if the next sentence is not spoken yet it returns
 * what there is, and [isWaiting] says so. A slow voice's sentences are kept on disk in a [VoiceCache] when
 * [VoicedTextOptions.cacheDirectory] is given, and read from there next time. Everything is safe to call from any
 * thread.
 *
 * Two clocks: the frames [read] returns, counted from the frame the last seek returned; and the timeline, the text's
 * characters at [secondsPerCharacter] each, which is the same whatever the voice and the speed. [timeAt] maps the
 * first to the second. Character positions are indices into the string (UTF-16), as everywhere in Kotlin and Java.
 * Times are in seconds.
 *
 * The reader owns its voices: it closes each one when it is replaced and when the reader is closed, always on its own
 * thread and never while the voice is speaking.
 */
class VoicedText private constructor(
    /** The text being read. */
    val text: String,
    voice: SentenceVoice,
    voiceId: String,
    private val factory: VoiceFactory?,
    options: VoicedTextOptions,
    private val codec: VoiceCache.Codec?,
) : AutoCloseable {

    /** Reads [text] with [voice], starting to speak the first sentences at once. */
    @JvmOverloads
    constructor(text: String, voice: SentenceVoice, options: VoicedTextOptions = VoicedTextOptions()) :
        this(text, voice, voice.id, null, options, null)

    /**
     * Reads [text] with the voice [voiceFactory] makes for [voiceId] (made now, on this thread). [setVoice] with an id
     * makes later voices the same way, on the reader's thread.
     */
    @JvmOverloads
    constructor(text: String, voiceId: String, voiceFactory: VoiceFactory, options: VoicedTextOptions = VoicedTextOptions()) :
        this(text, voiceFactory.create(voiceId), voiceId, voiceFactory, options, null)

    /** For the unit tests, which keep the cache in a codec of their own (they have no MediaCodec). */
    internal constructor(text: String, voice: SentenceVoice, options: VoicedTextOptions, codec: VoiceCache.Codec) :
        this(text, voice, voice.id, null, options, codec)

    internal constructor(text: String, voiceId: String, voiceFactory: VoiceFactory, options: VoicedTextOptions, codec: VoiceCache.Codec) :
        this(text, voiceFactory.create(voiceId), voiceId, voiceFactory, options, codec)

    private class Segment(val inputStart: Long, val sentence: Int, var frames: Int, val total: Int)
    private class Mark(val frame: Long, val character: Double)

    private val lock = Object()
    private val wake = Wake()
    private val worker: Thread
    private val cacheDirectory: File? = options.cacheDirectory
    private val speakAheadToDiskAsk: (() -> Boolean)? = options.speakAheadToDisk
    private val stream: SpeechwarpStream?

    // Spoken sentences at sampleRate, by index; empty for one with nothing to say (or that failed).
    private val ready = HashMap<Int, FloatArray>()
    // Sentences of blocks not yet complete, to be kept once they are.
    private val building = HashMap<Int, Array<FloatArray?>>()
    // Where each sentence's audio sits in what has been read since the last seek (before any speed-up).
    private val segments = ArrayList<Segment>()
    // Frames returned by read, and the character there.
    private val marks = ArrayList<Mark>()
    private val retired = ArrayList<SentenceVoice>()

    private var currentVoice: SentenceVoice = voice
    private var currentId: String = voiceId
    private var cache: VoiceCache? = null
    private var pendingId: String? = null
    private var generation = 0 // raised by a new voice: what was being spoken before it is not used
    private var lookaheadSeconds: Double
    private var keptLookaheadSeconds: Double
    private var feeding = 0 // the sentence being read (or written into the stream)
    private var fed = 0 // frames of it taken
    private var input = 0L // frames of speech taken since the last seek
    private var frame = 0L // frames returned, counted from the frame the last seek returned
    private var flushed = false
    private var waiting = false
    private var failure: Throwable? = null
    private var scratch = FloatArray(0) // for read(ShortArray)
    @Volatile private var closed = false

    /** The text cut into sentences (by [Sentence.split]). */
    val sentences: List<Sentence>

    /** The sample rate of what [read] returns. */
    val sampleRate: Int

    /** Channels of what [read] returns: always 1. */
    val channels: Int get() = 1

    /** The timeline's pace: seconds a character. */
    val secondsPerCharacter: Double

    /** The length of the timeline in seconds: every character at [secondsPerCharacter]. */
    val duration: Double get() = text.length * secondsPerCharacter

    /** Whether the audio goes through speechwarp (see [VoicedTextOptions.speedUp]). */
    val speedsUp: Boolean get() = stream != null

    init {
        require(options.secondsPerCharacter > 0) { "secondsPerCharacter must be more than 0" }
        sentences = Sentence.split(text, options.locale ?: Locale.getDefault())
        lookaheadSeconds = max(1.0, options.lookahead)
        keptLookaheadSeconds = max(1.0, options.keptLookahead)
        secondsPerCharacter = options.secondsPerCharacter
        sampleRate = options.sampleRate ?: voice.sampleRate
        require(sampleRate > 0) { "The sample rate must be more than 0" }
        stream = if (options.speedUp) SpeechwarpStream(sampleRate, 1) else null
        cache = cacheFor(voice)
        marks.add(Mark(0, 0.0))
        worker = Thread(::work, "speechwarp-voice reader").apply {
            isDaemon = true
            priority = Thread.NORM_PRIORITY + 1
        }
        worker.start()
    }

    /** The voice reading now (until one asked for by [setVoice] with an id has been made). */
    val voice: SentenceVoice get() = synchronized(lock) { currentVoice }

    /**
     * The id of the voice reading, or of the voice asked for if it has not taken over yet: the id given to the factory
     * for a voice it made, otherwise [SentenceVoice.id].
     */
    val voiceId: String get() = synchronized(lock) { pendingId ?: currentId }

    /**
     * speechwarp's speed: 2 plays twice as fast as the voice speaks. Default 1.
     *
     * @throws IllegalStateException when set on a reader that does not speed up ([speedsUp]), or after [close]
     */
    var speed: Float
        get() = synchronized(lock) { if (stream == null || closed) 1f else stream.speed }
        set(value) {
            synchronized(lock) {
                checkNotNull(stream) { "This reader does not speed up (VoicedTextOptions.speedUp is false)" }
                check(!closed) { "The reader is closed" }
                stream.speed = value
            }
            wake.set()
        }

    /** Seconds of listening to keep spoken ahead for a fast voice. At least 1. */
    var lookahead: Double
        get() = synchronized(lock) { lookaheadSeconds }
        set(value) {
            synchronized(lock) { lookaheadSeconds = max(1.0, value) }
            wake.set()
        }

    /** Seconds of listening to keep spoken ahead for a slow voice ([SentenceVoice.keepsSpoken]). At least 1. */
    var keptLookahead: Double
        get() = synchronized(lock) { keptLookaheadSeconds }
        set(value) {
            synchronized(lock) { keptLookaheadSeconds = max(1.0, value) }
            wake.set()
        }

    /** The index in the text of what [read] has reached (approximate within a sentence). */
    val characterPosition: Int get() = synchronized(lock) { reached().toInt() }

    /** The place on the timeline, in seconds, of what [read] has reached. */
    val position: Double get() = synchronized(lock) { reached() } * secondsPerCharacter

    /** The sentence [read] has reached. */
    val sentenceIndex: Int get() = synchronized(lock) { sentenceAt(reached().toInt()) }

    /** The last [read] returned less than asked because the next sentence was still being spoken. */
    val isWaiting: Boolean get() = synchronized(lock) { waiting }

    /** The same as [isWaiting]. */
    val isBuffering: Boolean get() = isWaiting

    /** Everything has been read. */
    val isFinished: Boolean
        get() = synchronized(lock) {
            if (stream == null) feeding >= sentences.size else flushed && (closed || stream.framesAvailable == 0)
        }

    /** The most recent failure to speak a sentence (which is then skipped), to make a voice or to keep a block, if any. */
    val lastError: Throwable? get() = synchronized(lock) { failure }

    /**
     * Changes the speechwarp stream's other settings (nonlinear amount, heard pause, floor blend, rhythm ...) safely.
     * Do not keep the stream.
     *
     * @throws IllegalStateException when the reader does not speed up ([speedsUp]), or after [close]
     */
    fun configure(change: (SpeechwarpStream) -> Unit) {
        synchronized(lock) {
            checkNotNull(stream) { "This reader does not speed up (VoicedTextOptions.speedUp is false)" }
            check(!closed) { "The reader is closed" }
            change(stream)
        }
        wake.set()
    }

    /**
     * Carries on in the voice the factory makes for [voiceId]. The voice is made on the reader's thread (it may take a
     * while: a neural model, say), so this returns at once; once it is made it reads from the next sentence not yet
     * started. A failure to make it is reported in [lastError] and the old voice carries on.
     *
     * @throws IllegalStateException when the reader was made without a factory, or after [close]
     */
    fun setVoice(voiceId: String) {
        checkNotNull(factory) { "This reader was made with a voice, not a factory: pass a SentenceVoice" }
        synchronized(lock) {
            check(!closed) { "The reader is closed" }
            pendingId = voiceId
        }
        wake.set()
    }

    /**
     * Carries on in [voice] from the next sentence not yet started (what is spoken in the old voice beyond that is
     * dropped). The reader owns it from now on.
     *
     * @throws IllegalStateException after [close]
     */
    fun setVoice(voice: SentenceVoice) {
        synchronized(lock) {
            check(!closed) { "The reader is closed" }
            pendingId = null // this one wins over any still being made
            install(voice, voice.id)
        }
        wake.set()
    }

    /**
     * Fills [samples] from [offset] with what to play next (mono); returns the frames written, fewer than [length]
     * when the next sentence is not spoken yet ([isWaiting]) or at the end. Never waits.
     */
    @JvmOverloads
    fun read(samples: FloatArray, offset: Int = 0, length: Int = samples.size - offset): Int {
        if (offset < 0 || length < 0 || offset > samples.size - length) {
            throw IndexOutOfBoundsException("offset $offset and length $length do not fit an array of ${samples.size}")
        }
        val frames: Int
        val advanced: Boolean
        synchronized(lock) {
            if (closed) return 0
            val before = feeding
            if (stream != null) {
                feed(length)
                frames = stream.read(samples, offset, length)
                waiting = frames < length && !flushed
            } else {
                frames = copy(samples, offset, length)
                waiting = frames < length && feeding < sentences.size
            }
            advanced = feeding != before
            if (frames > 0) {
                frame += frames
                marks.add(Mark(frame, reached()))
                if (marks.size > 4000) marks.subList(0, 2000).clear()
            }
        }
        if (advanced || frames < length) wake.set()
        return frames
    }

    /** As [read] for floats, in 16-bit samples. Allocates a buffer the first time (and when a longer read comes). */
    @JvmOverloads
    fun read(samples: ShortArray, offset: Int = 0, length: Int = samples.size - offset): Int {
        if (offset < 0 || length < 0 || offset > samples.size - length) {
            throw IndexOutOfBoundsException("offset $offset and length $length do not fit an array of ${samples.size}")
        }
        val buffer = synchronized(lock) {
            if (scratch.size < length) scratch = FloatArray(length)
            scratch
        }
        // The scratch buffer is shared; reads come from one audio thread, but stay safe if they do not.
        synchronized(buffer) {
            val frames = read(buffer, 0, length)
            for (i in 0 until frames) samples[offset + i] = toShort(buffer[i])
            return frames
        }
    }

    /**
     * Continues from the start of the sentence containing character [character]; returns the frame that start has on
     * the timeline (its time × [sampleRate]), from which later frames are counted.
     */
    fun seekToCharacter(character: Int): Long {
        val result: Long
        synchronized(lock) {
            val at = character.coerceIn(0, text.length)
            feeding = sentenceAt(at)
            fed = 0
            if (!closed) stream?.reset()
            flushed = false
            segments.clear()
            input = 0
            val start = if (feeding < sentences.size) sentences[feeding].start else text.length
            result = (start * secondsPerCharacter * sampleRate).roundToLong()
            frame = result
            marks.clear()
            marks.add(Mark(frame, start.toDouble()))
            // What is spoken from here on still serves; behind it does not.
            ready.keys.removeAll { it < feeding }
            waiting = false
        }
        wake.set()
        return result
    }

    /** Continues from the start of the sentence at [seconds] on the timeline; returns its frame (see [seekToCharacter]). */
    fun seekToTime(seconds: Double): Long =
        seekToCharacter((seconds / secondsPerCharacter).coerceIn(0.0, text.length.toDouble()).toInt())

    /**
     * The place on the timeline, in seconds, of frame [frame] of what [read] returned, counted from the frame the last
     * seek returned (0 before any). Recent frames only: it remembers the last few thousand reads.
     */
    fun timeAt(frame: Long): Double = characterAt(frame) * secondsPerCharacter

    /** The character of the text at frame [frame] (see [timeAt]), fractional within a sentence. */
    fun characterAt(frame: Long): Double = synchronized(lock) {
        val i = marks.indexOfLast { it.frame <= frame }
        if (i < 0) return marks[0].character
        val from = marks[i]
        var character = from.character
        if (i + 1 < marks.size && marks[i + 1].frame > from.frame) {
            val next = marks[i + 1]
            character += (next.character - character) * (frame - from.frame) / (next.frame - from.frame)
        }
        character
    }

    // Reading (with the lock held).

    /** Writes spoken sentences into the stream until it has [wanted] frames or the next is not spoken. */
    private fun feed(wanted: Int) {
        val stream = stream!!
        while (stream.framesAvailable < wanted && !flushed) {
            if (feeding >= sentences.size) {
                stream.flush()
                flushed = true
                return
            }
            val audio = ready[feeding] ?: return // not spoken yet
            val take = minOf(4096, audio.size - fed)
            if (take > 0) {
                stream.write(audio, fed, take)
                taken(audio, take)
            }
            if (fed >= audio.size) advance()
        }
    }

    /** Copies spoken sentences straight into [samples], for a reader that does not speed up. */
    private fun copy(samples: FloatArray, offset: Int, length: Int): Int {
        var written = 0
        while (written < length && feeding < sentences.size) {
            val audio = ready[feeding] ?: break
            val take = minOf(length - written, audio.size - fed)
            if (take > 0) {
                audio.copyInto(samples, offset + written, fed, fed + take)
                written += take
                taken(audio, take)
            }
            if (fed >= audio.size) advance()
        }
        return written
    }

    private fun taken(audio: FloatArray, take: Int) {
        val last = segments.lastOrNull()
        if (last != null && last.sentence == feeding) last.frames += take
        else segments.add(Segment(input, feeding, take, audio.size))
        input += take
        fed += take
        // Segments wholly behind what is heard are no longer needed.
        if (segments.size > 64) {
            val heard = heard()
            val keep = segments.indexOfLast { it.inputStart <= heard }
            if (keep > 0) segments.subList(0, keep).clear()
        }
    }

    private fun advance() {
        feeding++
        fed = 0
        // A little is kept behind for short seeks.
        ready.keys.removeAll { it < feeding - 2 }
    }

    /** Frames of speech (before any speed-up) heard since the last seek. */
    private fun heard(): Long = if (stream == null) input else if (closed) 0 else stream.position

    /** The character reached, fractional within a sentence. */
    private fun reached(): Double {
        val heard = heard()
        val index = segments.indexOfLast { it.inputStart <= heard }
        if (index < 0) return if (feeding < sentences.size) sentences[feeding].start.toDouble() else text.length.toDouble()
        val segment = segments[index]
        val sentence = sentences[segment.sentence]
        val into = ((heard - segment.inputStart).toDouble() / max(1, segment.total)).coerceIn(0.0, 1.0)
        return sentence.start + into * sentence.length
    }

    private fun sentenceAt(character: Int): Int {
        for (i in sentences.indices.reversed()) if (sentences[i].start <= character) return i
        return 0
    }

    // Speaking ahead, on the reader's thread.

    private fun work() {
        while (!closed) {
            try {
                if (takePendingVoice()) continue
                closeRetired()
                if (!speakNext()) wake.await(500)
            } catch (e: Throwable) {
                if (e is VirtualMachineError) throw e
                synchronized(lock) { failure = e }
                wake.await(500)
            }
        }
        // Closed: the voices are let go here, where nothing can be speaking with them.
        val voices: List<SentenceVoice>
        synchronized(lock) {
            val seen = Collections.newSetFromMap(IdentityHashMap<SentenceVoice, Boolean>())
            voices = (retired + currentVoice).filter { seen.add(it) }
            retired.clear()
        }
        for (voice in voices) closeQuietly(voice)
    }

    /** Makes the voice asked for by id and puts it in place. False when none was asked for. */
    private fun takePendingVoice(): Boolean {
        val id = synchronized(lock) { pendingId } ?: return false
        val next = try {
            factory!!.create(id)
        } catch (e: Exception) {
            synchronized(lock) {
                failure = e
                if (pendingId == id) pendingId = null // carry on in the old voice
            }
            return true
        }
        synchronized(lock) {
            if (pendingId != id) {
                retired.add(next) // another voice was asked for meanwhile; that one wins
                return true
            }
            pendingId = null
            install(next, id)
        }
        return true
    }

    /** Puts [next] in place from the next sentence not yet started (with the lock held). */
    private fun install(next: SentenceVoice, id: String) {
        if (next !== currentVoice) retired.add(currentVoice)
        currentVoice = next
        currentId = id
        cache = cacheFor(next)
        building.clear()
        generation++
        ready.keys.removeAll { it > feeding || (it == feeding && fed == 0) }
    }

    /** Speaks (or loads from the cache) the next sentence missing within the lookahead. False when none is. */
    private fun speakNext(): Boolean {
        val index: Int
        val generation: Int
        val speaker: SentenceVoice
        val cache: VoiceCache?
        synchronized(lock) {
            generation = this.generation
            speaker = currentVoice
            cache = this.cache
            index = nextMissing(if (speaker.keepsSpoken) keptLookaheadSeconds else lookaheadSeconds)
        }
        if (index < 0) {
            val ask = speakAheadToDiskAsk
            return cache != null && ask != null && ask() && speakAheadToDisk(speaker, cache, generation)
        }

        val block = VoiceCache.blockOf(index)
        val kept = cache?.load(block, sampleRate)
        if (kept != null) {
            synchronized(lock) {
                if (generation != this.generation) return true
                for (i in kept.indices) {
                    val sentence = block * VoiceCache.BLOCK_SIZE + i
                    if (sentence >= feeding && sentence < sentences.size) ready.getOrPut(sentence) { kept[i] } // HashMap.putIfAbsent needs API 24
                }
                // A seek past it while it loaded leaves it unneeded, not short.
                if (ready.containsKey(index) || index < feeding) return true
            }
            cache?.remove(block) // shorter than it should be: speak it again
        }

        val spoken = speak(speaker, index)
        synchronized(lock) {
            if (generation != this.generation) return true
            if (index >= feeding) ready[index] = spoken ?: FloatArray(0)
        }
        if (cache != null) build(cache, index, spoken, generation)
        return true
    }

    /** The first sentence from the one being read that is not spoken, within [lookahead] s; -1 for none. */
    private fun nextMissing(lookahead: Double): Int {
        val speed = max(if (stream == null || closed) 1.0 else stream.speed.toDouble(), 0.05)
        var ahead = 0.0
        var i = feeding
        while (i < sentences.size && ahead < lookahead) {
            val audio = ready[i] ?: return i
            ahead += (audio.size - (if (i == feeding) fed else 0)) / sampleRate.toDouble() / speed
            i++
        }
        return -1
    }

    /** The sentence spoken and converted to [sampleRate]; null if the voice failed. */
    private fun speak(speaker: SentenceVoice, index: Int): FloatArray? = try {
        val samples = speaker.speak(sentences[index].text)
        if (speaker.sampleRate == sampleRate) samples else AudioResampling.linear(samples, speaker.sampleRate, sampleRate)
    } catch (e: Exception) {
        synchronized(lock) { failure = e }
        null
    }

    /** Adds a sentence to its block, and keeps the block once every sentence of it is spoken. */
    private fun build(cache: VoiceCache, index: Int, spoken: FloatArray?, generation: Int) {
        val block = VoiceCache.blockOf(index)
        var complete: List<FloatArray>? = null
        synchronized(lock) {
            if (generation != this.generation) return
            if (spoken == null) {
                building.remove(block) // a failure is not kept: the block is spoken again another time
                return
            }
            val parts = building.getOrPut(block) {
                arrayOfNulls(minOf(VoiceCache.BLOCK_SIZE, sentences.size - block * VoiceCache.BLOCK_SIZE))
            }
            parts[index % VoiceCache.BLOCK_SIZE] = spoken
            if (parts.all { it != null }) {
                complete = parts.map { it!! }
                building.remove(block)
            }
            // Blocks left part-spoken by a seek are let go.
            val current = VoiceCache.blockOf(feeding)
            building.keys.removeAll { it < current }
        }
        complete?.let { keep(cache, block, it) }
    }

    /**
     * The first block from the one being read that is not on disk, completed (with what is already spoken of it) and
     * kept. False when there is none.
     */
    private fun speakAheadToDisk(speaker: SentenceVoice, cache: VoiceCache, generation: Int): Boolean {
        val blocks = VoiceCache.blockCount(sentences.size)
        val first = synchronized(lock) { VoiceCache.blockOf(feeding) }
        val block = (first until blocks).firstOrNull { !cache.has(it) } ?: return false
        val start = block * VoiceCache.BLOCK_SIZE
        val parts = arrayOfNulls<FloatArray>(minOf(VoiceCache.BLOCK_SIZE, sentences.size - start))
        for (i in parts.indices) {
            synchronized(lock) {
                // Back to the sentences being read as soon as they are wanted.
                if (closed || generation != this.generation || pendingId != null ||
                    nextMissing((if (speaker.keepsSpoken) keptLookaheadSeconds else lookaheadSeconds) / 2) >= 0
                ) return true
                building[block]?.get(i)?.let { parts[i] = it }
            }
            if (parts[i] == null) parts[i] = speak(speaker, start + i) ?: return true
        }
        synchronized(lock) {
            if (generation != this.generation) return true
            building.remove(block)
        }
        keep(cache, block, parts.map { it!! })
        return true
    }

    private fun keep(cache: VoiceCache, block: Int, sentences: List<FloatArray>) {
        try {
            cache.save(block, sentences, sampleRate)
        } catch (e: Exception) {
            synchronized(lock) { failure = e }
        }
    }

    private fun cacheFor(voice: SentenceVoice): VoiceCache? {
        val directory = cacheDirectory ?: return null
        if (!voice.keepsSpoken) return null
        return if (codec != null) VoiceCache(text, voice.id, directory, codec) else VoiceCache(text, voice.id, directory)
    }

    private fun closeRetired() {
        val list: List<SentenceVoice>
        synchronized(lock) {
            if (retired.isEmpty()) return
            list = retired.filter { it !== currentVoice }
            retired.clear()
        }
        for (voice in list) closeQuietly(voice)
    }

    private fun closeQuietly(voice: SentenceVoice) {
        try {
            voice.close()
        } catch (e: Exception) {
            synchronized(lock) { failure = e }
        }
    }

    /**
     * Stops speaking and releases the stream. The voices are closed on the reader's thread once it has finished the
     * sentence it is speaking, so this never waits.
     */
    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            stream?.close()
        }
        wake.set()
    }
}

/** An auto-reset event: [set] lets one [await] through (now or the next to come). */
internal class Wake {
    private val lock = Object()
    private var signalled = false

    fun set() = synchronized(lock) {
        signalled = true
        lock.notifyAll()
    }

    fun await(milliseconds: Long) = synchronized(lock) {
        val end = System.nanoTime() + milliseconds * 1_000_000
        while (!signalled) {
            val left = (end - System.nanoTime()) / 1_000_000
            if (left <= 0) break
            lock.wait(left)
        }
        signalled = false
    }
}
