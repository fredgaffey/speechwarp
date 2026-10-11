package io.github.fredgaffey.speechwarp.voice.espeak

import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.io.IOException

/**
 * eSpeak NG, linked into the app: speech in its own formant voices, and text to phonemes (IPA) for neural voices
 * such as Kokoro.
 *
 * eSpeak reads its data from files. The library carries eSpeak's English data in the app's assets, and
 * [initialize] copies it to the app's files folder (once, and again only when it changes) and points eSpeak at it.
 * Call it once before anything else, or set [dataPath] to data of your own.
 *
 * eSpeak keeps its state in globals and is not thread-safe, so every call here takes one lock: calls from several
 * threads take turns. eSpeak starts on the first call that needs it. eSpeak NG is licensed under the
 * GPL-3.0-or-later; so is this library, and an app that uses it.
 */
object Espeak {
    /** The default speaking rate, in words a minute. */
    const val DEFAULT_WORDS_PER_MINUTE = 175

    /** The default pitch, 0 to 100. */
    const val DEFAULT_PITCH = 50

    /** Where the data is in the assets, and under the files folder: speechwarp-espeak/espeak-ng-data. */
    private const val ASSETS = "speechwarp-espeak"
    private const val DATA = "espeak-ng-data"

    /** A hash of the data, written by the build beside it, to tell whether the copy in the files folder is current. */
    private const val STAMP = "stamp"

    private val lock = Any()
    private var started = false
    private var path: File? = null
    private var voice: String? = null

    /**
     * The folder of eSpeak's data, espeak-ng-data, or null until [initialize] has been called or it has been set.
     *
     * Set it to use data of your own instead of the library's; set it before the first call that uses eSpeak.
     *
     * @throws IllegalStateException On setting, when eSpeak has already started with other data.
     */
    @JvmStatic
    var dataPath: File?
        get() = synchronized(lock) { path }
        set(value) = synchronized(lock) {
            check(!started || value == path) { "eSpeak has started; set its data path before using it." }
            path = value
        }

    /**
     * Puts the library's eSpeak data (English, in each of eSpeak's accents, and every voice variant; about 1.2 MB)
     * in the app's files folder, unless it is there already, and uses it unless [dataPath] has been set. Quick after
     * the first time in each version of the app; the first time it copies the files, so call it off the main
     * thread.
     *
     * @return The data folder: files/speechwarp-espeak/espeak-ng-data.
     * @throws IOException The data could not be copied.
     */
    @JvmStatic
    fun initialize(context: Context): File = synchronized(lock) {
        val assets = context.applicationContext?.assets ?: context.assets
        val folder = File(context.applicationContext?.filesDir ?: context.filesDir, ASSETS)
        val data = File(folder, DATA)
        // Once eSpeak has started from this copy it is in use, and stays as it is for the life of the process.
        if (!(started && path == data)) install(assets, folder)
        if (path == null) path = data
        data
    }

    /** eSpeak NG's version, such as "1.52.0". */
    @JvmStatic
    val version: String
        get() = synchronized(lock) { EspeakNative.version().substringBefore(' ') }

    /**
     * Frames a second of what [speak] returns: 22,050.
     *
     * @throws IllegalStateException eSpeak could not start (its data is missing).
     */
    @JvmStatic
    val sampleRate: Int
        get() = synchronized(lock) {
            start()
            EspeakNative.sampleRate()
        }

    /**
     * [text] spoken by eSpeak in the voice [language]: mono samples, -1 to 1, at [sampleRate], empty for nothing to
     * say. The defaults, 175 words a minute and pitch 50, are eSpeak's own.
     *
     * @param text The text, plain (not SSML).
     * @param language A voice: a language such as "en-us", "en-gb", "en-gb-x-rp" or "en-029" (see [voices]),
     * optionally with a variant, such as "en-us+klatt" (see [variants]).
     * @param wordsPerMinute Speaking rate, 80 to 450 (eSpeak keeps it within those).
     * @param pitch Pitch, 0 to 100.
     * @throws IllegalArgumentException eSpeak has no voice [language].
     * @throws IllegalStateException eSpeak could not start, or failed to speak.
     */
    @JvmStatic
    @JvmOverloads
    fun speak(
        text: String,
        language: String,
        wordsPerMinute: Int = DEFAULT_WORDS_PER_MINUTE,
        pitch: Int = DEFAULT_PITCH,
    ): FloatArray = synchronized(lock) {
        start()
        use(language)
        if (text.isBlank()) return FloatArray(0)
        EspeakNative.synthesize(text.toByteArray(Charsets.UTF_8), wordsPerMinute, pitch.coerceIn(0, 100))
    }

    /**
     * The phonemes of [text] in IPA, with eSpeak's stress marks, clause by clause (clauses are separated by a
     * space), for the voice [language] ("en-us", "en-gb" and the rest).
     *
     * @throws IllegalArgumentException eSpeak has no voice [language].
     * @throws IllegalStateException eSpeak could not start.
     */
    @JvmStatic
    @JvmOverloads
    fun phonemes(text: String, language: String = "en-us"): String = synchronized(lock) {
        start()
        use(language)
        String(EspeakNative.textToPhonemes(text.toByteArray(Charsets.UTF_8)), Charsets.UTF_8)
    }

    /**
     * The voices in eSpeak's data, one per language and accent, sorted by name. The library's data has English only:
     * America, New York, Britain, Received Pronunciation, Scotland, Lancaster, West Midlands, the Caribbean and
     * Shavian.
     *
     * @throws IllegalStateException eSpeak could not start.
     */
    @JvmStatic
    val voices: List<EspeakVoice>
        get() = synchronized(lock) {
            start()
            String(EspeakNative.listVoices(), Charsets.UTF_8).lineSequence().mapNotNull { EspeakVoice.parse(it) }.toList()
        }

    /**
     * The voice variants in eSpeak's data, such as "klatt", "f3" or "m1": added to a voice after a '+'
     * ("en-us+klatt"), they change its sound (the Klatt variants use a different synthesiser). Empty before the
     * data is in place.
     */
    @JvmStatic
    val variants: List<String>
        get() {
            val folder = File(dataPath ?: return emptyList(), "voices/!v")
            return folder.listFiles()?.filter { it.isFile }?.map { it.name }?.sortedWith(String.CASE_INSENSITIVE_ORDER)
                ?: emptyList()
        }

    // Called with the lock held.
    private fun start() {
        if (started) return
        val data = checkNotNull(path) {
            "eSpeak's data is not in place: call Espeak.initialize(context) first, or set Espeak.dataPath."
        }
        val status = EspeakNative.initialize(data.path.toByteArray(Charsets.UTF_8))
        check(status == 0) { "eSpeak could not start with its data at $data (status 0x${Integer.toHexString(status)})." }
        started = true
    }

    // Called with the lock held.
    private fun use(language: String) {
        if (voice == language) return
        // eSpeak finds a voice by its name or file name ("en-us" is lang/gmw/en-US), but not by a language that names
        // no file: "en-gb" is lang/gmw/en. Then ask it for the voice that suits the language best, as its own
        // command does, and keep any variant ("en-gb+klatt").
        if (EspeakNative.setVoiceByName(language.toByteArray(Charsets.UTF_8)) != 0) {
            val identifier = bestVoiceFor(language)
            require(identifier != null && EspeakNative.setVoiceByName(identifier.toByteArray(Charsets.UTF_8)) == 0) {
                "eSpeak has no voice '$language'."
            }
        }
        voice = language
    }

    // The file of the voice that suits a language best, with the language's variant, or null. Called with the lock held.
    private fun bestVoiceFor(language: String): String? {
        val plus = language.indexOf('+')
        val name = if (plus < 0) language else language.substring(0, plus)
        val variant = if (plus < 0) "" else language.substring(plus)
        if (name.isEmpty()) return null
        val identifier = EspeakNative.bestVoiceFor(name.toByteArray(Charsets.UTF_8)) ?: return null
        return String(identifier, Charsets.UTF_8) + variant
    }

    /** Copies the assets' data to folder/espeak-ng-data unless the copy there has the same stamp. */
    private fun install(assets: AssetManager, folder: File) {
        val stamp = try {
            assets.open("$ASSETS/$STAMP").use { String(it.readBytes(), Charsets.UTF_8).trim() }
        } catch (e: IOException) {
            throw IOException("The library's eSpeak data is missing from the app's assets.", e)
        }
        val stampFile = File(folder, STAMP)
        val data = File(folder, DATA)
        if (data.isDirectory && stampFile.isFile && stampFile.readText().trim() == stamp) return

        // Into a fresh folder first, then renamed, so a copy cut short is never taken for a whole one.
        folder.mkdirs()
        val fresh = File(folder, "$DATA.new")
        fresh.deleteRecursively()
        copyAssets(assets, "$ASSETS/$DATA", fresh)
        stampFile.delete()
        data.deleteRecursively()
        if (!fresh.renameTo(data)) throw IOException("Could not move eSpeak's data into place at $data.")
        stampFile.writeText(stamp)
    }

    private fun copyAssets(assets: AssetManager, from: String, to: File) {
        val children = assets.list(from).orEmpty()
        if (children.isEmpty()) {
            // A file (the asset manager lists no children for a file, nor for an empty folder, which has none here).
            to.parentFile?.mkdirs()
            assets.open(from).use { input -> to.outputStream().use { input.copyTo(it) } }
            return
        }
        to.mkdirs()
        for (child in children) copyAssets(assets, "$from/$child", File(to, child))
    }
}
