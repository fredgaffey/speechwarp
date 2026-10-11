package io.github.fredgaffey.speechwarp.voice

import android.content.Context
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/**
 * Sentences a slow voice (one whose [SentenceVoice.keepsSpoken] is true, such as Kokoro) has already spoken, kept on
 * disk so that they need not be spoken again.
 *
 * The sentences of a text (as [Sentence.split] cuts it) are kept in blocks of [BLOCK_SIZE]: each block is an AAC file
 * (32 kbit/s, mono, in an MPEG-4 container, at the voice's rate or the next one up that AAC has) with the length of
 * each sentence in a small JSON file beside it, which is written last, so a block is there only once both are. About
 * 150 MB for a ten-hour book.
 *
 * Each text and voice has a folder of its own: `directory/TEXT/VOICE/`, where TEXT is the first 16 hex digits of the
 * SHA-256 of the text (UTF-8) and VOICE is the voice id with characters a file name cannot hold replaced by '-'. The
 * usual directory, [defaultDirectory], is in the app's cache directory, which Android may clear when space runs
 * short; a block that has gone, or cannot be read, is simply spoken again.
 *
 * Safe to use from several threads at once, as far as the file system is: a block is written to a temporary file
 * and moved into place. Encoding and decoding use the platform's MediaCodec, so call [load] and [save] off the main
 * thread.
 *
 * @param text the whole text, as given to [VoicedText]
 * @param voiceId the voice's [SentenceVoice.id]
 * @param root the directory holding every text and voice, such as [defaultDirectory]. Nothing is created until a
 * block is saved.
 */
class VoiceCache internal constructor(text: String, val voiceId: String, root: File, private val codec: Codec) {

    /** The cache of [text] spoken by the voice [voiceId], under [root]. */
    constructor(text: String, voiceId: String, root: File) : this(text, voiceId, root, AacCodec)

    /** How a block's audio is kept: AAC on a device; something simpler in the unit tests, which have no MediaCodec. */
    internal interface Codec {
        /** The extension of the files it writes, such as "m4a". */
        val extension: String
        /** The rate audio at [sampleRate] is kept at (converted to it before [write]). */
        fun storedRate(sampleRate: Int): Int = sampleRate
        fun write(file: File, samples: FloatArray, sampleRate: Int)
        fun read(file: File): Pcm
    }

    init {
        require(voiceId.isNotEmpty()) { "voiceId must not be empty" }
    }

    /** The folder kept for this text and voice. */
    val directory: File = File(File(root, textKey(text)), fileName(voiceId))

    private fun name(block: Int) = String.format(java.util.Locale.ROOT, "%05d", block)
    private fun audioFile(block: Int) = File(directory, name(block) + "." + codec.extension)
    private fun lengthsFile(block: Int) = File(directory, name(block) + ".json")

    /** Whether block [block] is kept. */
    fun has(block: Int): Boolean = lengthsFile(block).isFile && audioFile(block).isFile

    /**
     * Block [block]'s sentences, converted to [sampleRate]; null if it is not kept or cannot be read (then it is
     * deleted, to be spoken again).
     */
    fun load(block: Int, sampleRate: Int): Array<FloatArray>? {
        if (!has(block)) return null
        return try {
            val lengths = parseLengths(lengthsFile(block).readText())
            val all = codec.read(audioFile(block))
            // Less audio than the lengths say: the codec lost some of it, so every sentence after the loss would be
            // cut short. It is spoken again instead.
            if (all.samples.size < lengths.sum()) throw IOException("Block $block decoded short: ${all.samples.size} of ${lengths.sum()} samples")
            var at = 0
            Array(lengths.size) { i ->
                val take = lengths[i].coerceIn(0, all.samples.size - at)
                AudioResampling.linear(all.samples, all.sampleRate, sampleRate, at, take).also { at += take }
            }
        } catch (e: Exception) {
            remove(block)
            null
        }
    }

    /**
     * Keeps block [block]'s sentences, spoken at [sampleRate] (one array for each sentence of the block, empty for one
     * with nothing to say).
     *
     * @throws IOException if the block could not be written
     */
    fun save(block: Int, sentences: List<FloatArray>, sampleRate: Int) {
        if (!directory.isDirectory && !directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Could not make the folder $directory")
        }
        val audio = audioFile(block)
        val temp = File(directory, audio.name + "." + UUID.randomUUID().toString().replace("-", "") + ".part." + codec.extension)
        try {
            val rate = codec.storedRate(sampleRate)
            val kept = if (rate == sampleRate) sentences else sentences.map { AudioResampling.linear(it, sampleRate, rate) }
            val all = FloatArray(kept.sumOf { it.size })
            var at = 0
            for (sentence in kept) {
                sentence.copyInto(all, at)
                at += sentence.size
            }
            try {
                codec.write(temp, all, rate)
            } catch (e: IOException) {
                throw e
            } catch (e: Exception) {
                throw IOException("Could not encode block $block: ${e.message}", e)
            }
            if (!temp.renameTo(audio)) throw IOException("Could not move $temp to $audio")
            val lengths = lengthsFile(block)
            val lengthsTemp = File(directory, lengths.name + "." + UUID.randomUUID().toString().replace("-", "") + ".part")
            lengthsTemp.writeText(kept.joinToString(",", "[", "]") { it.size.toString() })
            if (!lengthsTemp.renameTo(lengths)) {
                lengthsTemp.delete()
                throw IOException("Could not move $lengthsTemp to $lengths")
            }
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    /** Forgets block [block]. */
    fun remove(block: Int) {
        lengthsFile(block).delete()
        audioFile(block).delete()
    }

    /** Forgets every block of this text in this voice. */
    fun clear() {
        directory.deleteRecursively()
    }

    companion object {
        /** Sentences in a block. */
        const val BLOCK_SIZE = 40

        /** The usual place for every text and voice: `speechwarp-voice` in the app's cache directory. */
        @JvmStatic
        fun defaultDirectory(context: Context): File = File(context.cacheDir, "speechwarp-voice")

        /** The folder name for a text: the first 16 hex digits of its SHA-256 (of its UTF-8). */
        @JvmStatic
        fun textKey(text: String): String {
            val hash = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            return hash.take(8).joinToString("") { String.format(java.util.Locale.ROOT, "%02x", it.toInt() and 0xFF) }
        }

        /** The block holding sentence [sentence]. */
        @JvmStatic
        fun blockOf(sentence: Int): Int = sentence / BLOCK_SIZE

        /** The number of blocks for [sentences] sentences. */
        @JvmStatic
        fun blockCount(sentences: Int): Int = (sentences + BLOCK_SIZE - 1) / BLOCK_SIZE

        private val number = Regex("-?\\d+")

        private fun parseLengths(json: String): IntArray {
            val trimmed = json.trim()
            if (!trimmed.startsWith("[") || !trimmed.endsWith("]")) throw IOException("Not a JSON array: $json")
            val inner = trimmed.substring(1, trimmed.length - 1)
            if (inner.isBlank()) return IntArray(0)
            return inner.split(',').map {
                val item = it.trim()
                if (!number.matches(item)) throw IOException("Not a length: $item")
                item.toInt()
            }.toIntArray()
        }

        /** A voice id as a folder name: letters, digits, '.', '_' and '-' kept, anything else '-' (and a leading '.'). */
        internal fun fileName(voiceId: String): String {
            val name = StringBuilder(voiceId.length)
            for (c in voiceId) {
                name.append(if (c in 'a'..'z' || c in 'A'..'Z' || c in '0'..'9' || c == '.' || c == '_' || c == '-') c else '-')
            }
            if (name[0] == '.') name.setCharAt(0, '-') // never "." or "..", nor hidden
            return name.toString()
        }
    }
}
