package io.github.fredgaffey.speechwarp.voice.kokoro

import java.io.File

/**
 * A file to download into the model directory.
 *
 * @property relativePath Where it goes in the model directory, such as "voices/af_heart.bin" ('/' between folders).
 * @property sizeBytes Its size.
 * @property url Where to download it: Hugging Face, at a fixed revision, so the hash always matches.
 * @property sha256 Lower-case hex SHA-256 of the file, to check the download.
 */
data class KokoroFile(val relativePath: String, val sizeBytes: Long, val url: String, val sha256: String)

/**
 * One of the model's variants: the same voices, stored more or less precisely.
 *
 * @property id Stable identifier, the file name without ".onnx", such as "model_fp16".
 * @property name A name to show, such as "Half precision (fp16)".
 * @property description What it is, in a sentence.
 * @property file The model file; its file name is what [KokoroOptions.modelFile] takes.
 */
data class KokoroModel(val id: String, val name: String, val description: String, val file: KokoroFile)

/**
 * A Kokoro voice.
 *
 * @property name The voice's name, such as "af_heart": the first letter is the language, the second the gender.
 * @property language The language its phonemes are made in, as [KokoroModels.languageOf] says.
 * @property isFemale The voice is a woman's (the second letter of its name is f).
 * @property file The voice's style file.
 */
data class KokoroVoice(val name: String, val language: String, val isFemale: Boolean, val file: KokoroFile)

/**
 * Where Kokoro's files go in the model directory, which ones a voice needs, and where to download them: the ONNX
 * export of Kokoro-82M v1.0 on Hugging Face (onnx-community/Kokoro-82M-v1.0-ONNX, Apache-2.0), at a fixed revision,
 * with each file's size and SHA-256. This library never uses the network; the app downloads what it needs.
 *
 * The model directory looks like this:
 * ```
 * model.onnx             (or another of models)
 * tokenizer.json
 * voices/af_heart.bin    (one file per voice, 510 rows of 256 floats)
 * ```
 * Only the English voices (American, first letter a, and British, b) have been tried; the others need a phonemizer
 * for their language, and Kokoro was trained on phonemes from misaki rather than eSpeak NG for some of them.
 */
object KokoroModels {
    /** The Hugging Face repository the files come from. */
    const val REPOSITORY = "onnx-community/Kokoro-82M-v1.0-ONNX"

    /** The repository's revision (commit) that every URL here names, so the hashes always match. */
    const val REVISION = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"

    /**
     * The model file the engine loads unless told otherwise: full precision, 326 MB. On Android's CPU it was the
     * fastest of the three tried and never gave NaN (docs/voices.md, "Which model on Android"); the C# package for
     * iOS defaults to fp16.
     */
    const val DEFAULT_MODEL_FILE = "model.onnx"

    /** The tokenizer's file name: the phoneme vocabulary. */
    const val TOKENIZER_FILE_NAME = "tokenizer.json"

    /** The folder in the model directory that holds the voices, one NAME.bin each. */
    const val VOICES_FOLDER = "voices"

    /** The voice to offer first: American English, a woman's voice, the one Kokoro's authors rate highest. */
    const val DEFAULT_VOICE = "af_heart"

    private const val BASE = "https://huggingface.co/$REPOSITORY/resolve/$REVISION/"

    /** The tokenizer, which every model needs. */
    @JvmStatic
    val tokenizer: KokoroFile = KokoroFile(
        TOKENIZER_FILE_NAME, 3497, BASE + TOKENIZER_FILE_NAME,
        "77a02c8e164413299b4b4c403b14f8e0e1c1b727db4d46a09d6327b861060a34",
    )

    /** The model's variants, the default ([DEFAULT_MODEL_FILE]) first. The order may change; keep the id. */
    @JvmStatic
    val models: List<KokoroModel> = listOf(
        model("model", "Full precision (fp32)",
            "The default on Android: weights in 32-bit floats, the original, twice the size of fp16.",
            325_532_232L, "8fbea51ea711f2af382e88c833d9e288c6dc82ce5e98421ea61c058ce21a34cb"),
        model("model_fp16", "Half precision (fp16)", "Weights in 16-bit floats, half the size of the full model.",
            163_234_740L, "ba4527a874b42b21e35f468c10d326fdff3c7fc8cac1f85e9eb6c0dfc35c334a"),
        model("model_q8f16", "8-bit and fp16 (q8f16)", "8-bit weights with the rest in 16-bit floats: the smallest.",
            86_033_585L, "04c658aec1b6008857c2ad10f8c589d4180d0ec427e7e6118ceb487e215c3cd0"),
        model("model_quantized", "8-bit (quantized)", "Weights in 8-bit integers.",
            92_361_116L, "fbae9257e1e05ffc727e951ef9b9c98418e6d79f1c9b6b13bd59f5c9028a1478"),
        model("model_uint8", "Unsigned 8-bit (uint8)", "Weights in unsigned 8-bit integers.",
            177_464_632L, "6607a397d77b8514065420b7c1e7320117f7aabfdb45ce15f0050c5b0fe75aea"),
        model("model_uint8f16", "Unsigned 8-bit and fp16 (uint8f16)", "Unsigned 8-bit weights with the rest in 16-bit floats.",
            114_209_226L, "883333e03c597584b532eebea0f8310f25f0c9ade58fe864792c12d969944a9a"),
        model("model_q4", "4-bit (q4)", "4-bit weights in the matrix multiplications, 32-bit floats elsewhere.",
            305_215_966L, "04cf570cf9c4153694f76347ed4b9a48c1b59ff1de0999e6605d123966b197c7"),
        model("model_q4f16", "4-bit and fp16 (q4f16)", "4-bit weights in the matrix multiplications, 16-bit floats elsewhere.",
            154_586_422L, "d1a508a6a29671ead84fac99c7401fbd3c21a583fc6ed1406d1ec974d53bf45f"),
    )

    /** Every voice in the repository, by language and then name. */
    @JvmStatic
    val voices: List<KokoroVoice> = listOf(
        voice("af_alloy", 522_240L, "c4a6b876047fd7fb472edf4ebd63cfac7c3b958a7cae7c106e8f038ca6308c45"),
        voice("af_aoede", 522_240L, "4a004c33430762e2461eedb2013fad808ef4ab3121f5300f554476caf58d8361"),
        voice("af_bella", 522_240L, "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"),
        voice("af_heart", 522_240L, "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"),
        voice("af_jessica", 522_240L, "a240a5e3c15b43563d6e923bdca8ef5613a23471d9b77653694012435df23bd8"),
        voice("af_kore", 522_240L, "9be5221b6a941c04b561959b8ff0b06e809444dcc4ab7e75a7b23606f691819e"),
        voice("af_nicole", 522_240L, "cd2191ab31b914ed7b318416b0e4440fdf392ddad9106a060819aa600a64f59a"),
        voice("af_nova", 522_240L, "18778272caa0d0eebaea251c35fd635f038434f9eee5e691d02a174bd328414f"),
        voice("af_river", 522_240L, "00a2bcf82b1d86e8f19902ede58c65ccf6c0e43b44b7d74fad54e5d8933c9c30"),
        voice("af_sarah", 522_240L, "4409fbc125afabacc615d94db5398d847006a737b0247d6892b7a9a0007a2f0a"),
        voice("af_sky", 522_240L, "4435255c9744f3f31659e0d714ab7689bf65d9e77ec1cce060f083912614f0b9"),
        voice("am_adam", 522_240L, "162b035ed91cfc48b6046982184c645f72edcdd1b82843347f605d7bf7b15716"),
        voice("am_echo", 522_240L, "3968b92c3c4cd1c4416dbded36c13eaa388a90d5788d02a13e4d781f5f8cf3c3"),
        voice("am_eric", 522_240L, "e8b5be17edd1e3636901ce7598baafe2dc8dd8ff707a0c23bf9e461add7e2832"),
        voice("am_fenrir", 522_240L, "c27989f741f7ee34d273a39d8a595cc0837d35f5ced9a29b7cc162614616df43"),
        voice("am_liam", 522_240L, "52403be32fd047c6a44517cb0bcd6b134f2a18baa73e70ef41651e0eab921ade"),
        voice("am_michael", 522_240L, "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
        voice("am_onyx", 522_240L, "da5d135b424164916d75a68ffb4c2abce3d7d5ccc82dd1ee6cf447ce286145e6"),
        voice("am_puck", 522_240L, "fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0"),
        voice("am_santa", 522_240L, "61150cf726ab6c5ed7a99f90a304f91f5a72c00c592e89ec94e5df11c319227a"),
        voice("bf_alice", 522_240L, "08afa6ba24da61ea5e8efa139e5aadc938d83f0a6da5a900adaf763ac1da5573"),
        voice("bf_emma", 522_240L, "669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73"),
        voice("bf_isabella", 522_240L, "3754352c4aaa46d17f27654ab7518d65b62ad6163a0f55a5f4330c2da2c4e94f"),
        voice("bf_lily", 522_240L, "5e0ee32ebe64a467124976b14e69590746f1c4ce41a12b587a50c862edfea335"),
        voice("bm_daniel", 522_240L, "6b3194bbceffb746733cbc22c8f593dd44e401a71d53895a2dca891bc595a1e8"),
        voice("bm_fable", 522_240L, "f889083196807b4adb15e9204252165f503b8d33d3982e681c52443c49d798f1"),
        voice("bm_george", 522_240L, "c4b235a4c1f2cd3b939fed08b899ce9385638b763f7b73a59616c4fc9bd6c9bc"),
        voice("bm_lewis", 522_240L, "b8f671cef828c30e66fdf0b0756a76bba58f6bb3398cbbf27058642acbcedb97"),
        voice("ef_dora", 522_240L, "f66ec66bd295acb18372e37008533a9a3228483ccd294e7538d5d9294ac9a532"),
        voice("em_alex", 522_240L, "27809e9eafdcbcfff90a3016c697568676531de2a2c39cee29c96c7bd6b83e95"),
        voice("em_santa", 522_240L, "ad43b774e1ca24d05c6161297d8aeb770ac3d29bb95daf516727af5f7d543683"),
        voice("ff_siwis", 522_240L, "a35f5675ad08948e326ae75fd0ea16ba5d0042e4f76b5f3d1df77d0a48c54861"),
        voice("hf_alpha", 522_240L, "040be6a4425411cc01fda5fd06693c76bfa78572632852bc8cda9c99232ffb56"),
        voice("hf_beta", 522_240L, "cd83ae0bb9b2e4e4fb92b4973bd8d1822ca0036d3c498bf4fc89aa8e33917cc7"),
        voice("hm_omega", 522_240L, "b02d9222d9ed00ce26b302173a862c2c93f96cc40b5c422b8d14910b9ff34137"),
        voice("hm_psi", 522_240L, "644daf88ba8aeb7bd08950bbdcd4453bb280864e49dc4df93fabc6be32e03f37"),
        voice("if_sara", 522_240L, "409b69248798fcdc2542330c76953d230710f19b057e59cb82fdc3c4cf71265c"),
        voice("im_nicola", 522_240L, "bc578e510d52a96d6940d46f12e96d7b3df00905dbea075113226d100e6e1ab0"),
        voice("jf_alpha", 522_240L, "56b479360aad9f367aeb8cef908f9201cf48b4555e488c5f4590c9dfcd978bb6"),
        voice("jf_gongitsune", 522_240L, "0f1181f3772d27b7c12aaf4bcd71e31b186c4146e330d074a3dc64ee392af396"),
        voice("jf_nezumi", 522_240L, "13cb71eebb0b48739d444558322aa35a8c9a489b80e1e631f14d2e6aea93026b"),
        voice("jf_tebukuro", 522_240L, "29c6c0561b4288d59639677bebe7533c919743d5ea68d0d2ae992644beea6696"),
        voice("jm_kumo", 522_240L, "09e959d239724c734d65661f06f14cdabcddfd476bfaaad905a937099ae9e64f"),
        voice("pf_dora", 522_240L, "3da7b5b2d91847ebf5646f57631af6ececae3c29a89cd300f06edf9aa6cfe9ee"),
        voice("pm_alex", 522_240L, "0175c753f59c54e7fd5a995bedef0c5ff2fb67e0043dd3dcb2ae74ec2acbeb2a"),
        voice("pm_santa", 522_240L, "8b012db3185778afe2e45a62cbad69db73021774fe68dda634bcc748a982eede"),
        voice("zf_xiaobei", 522_240L, "5dde6e1c9c4f12c8b327bc29c0cee361a23b52b952c04636858ba637ec66e640"),
        voice("zf_xiaoni", 522_240L, "08892b62a39af0a615cd0581238db7e19e44c578e8fa0bfd0e586e93327d9cba"),
        voice("zf_xiaoxiao", 522_240L, "03adb5d5e3ddd88b047954e974e651cb0a4b524c985057e5d872e962c7be1169"),
        voice("zf_xiaoyi", 522_240L, "bc1555c5c486099196ac254bae5e0bb543c121952a3092f50b7d8724f1bc36b3"),
        voice("zm_yunjian", 522_240L, "de48a00bdbf3649f07162269a2b6e0513604389bfac8a2e6c75cb34b323ad6fa"),
        voice("zm_yunxi", 522_240L, "7243892fb4e560d47014090ddf010f8b8b790f3c6b029ff82b2ac06aa4e27c8b"),
        voice("zm_yunxia", 522_240L, "6b2b8fc15b3df19a368daebe5c581c7fabf433ee5b8a17ffd6b3d723cff8936d"),
        voice("zm_yunyang", 522_240L, "261e2c89470534dbbcb8fd98b8fdc495ec94063d9bb6c8277f7be43cccba3f42")
    )

    /** The model whose id ("model_fp16") or file name ("model_fp16.onnx") this is, or null. */
    @JvmStatic
    fun findModel(idOrFileName: String): KokoroModel? =
        models.firstOrNull { it.id == idOrFileName || it.file.relativePath == idOrFileName }

    /** The voice named [name], such as "af_heart", or null. */
    @JvmStatic
    fun findVoice(name: String): KokoroVoice? = voices.firstOrNull { it.name == name }

    /**
     * The language a voice's phonemes are made in, from the first letter of its name, as kokoro-onnx names them for
     * eSpeak NG: a "en-us", b "en-gb", e "es", f "fr-fr", h "hi", i "it", j "ja", p "pt-br", z "cmn"; "en-us" for
     * anything else.
     */
    @JvmStatic
    fun languageOf(voice: String): String = when (voice.firstOrNull()) {
        'b' -> "en-gb"
        'e' -> "es"
        'f' -> "fr-fr"
        'h' -> "hi"
        'i' -> "it"
        'j' -> "ja"
        'p' -> "pt-br"
        'z' -> "cmn"
        else -> "en-us"
    }

    /** The model file's path in [directory]. */
    @JvmStatic
    @JvmOverloads
    fun modelPath(directory: File, modelFile: String = DEFAULT_MODEL_FILE): File = File(directory, modelFile)

    /** tokenizer.json's path in [directory]. */
    @JvmStatic
    fun tokenizerPath(directory: File): File = File(directory, TOKENIZER_FILE_NAME)

    /**
     * The voice's file, voices/NAME.bin, in [directory].
     *
     * @throws IllegalArgumentException The name is not a voice name (letters, digits, '_' and '-').
     */
    @JvmStatic
    fun voicePath(directory: File, voice: String): File {
        checkVoiceName(voice)
        return File(File(directory, VOICES_FOLDER), "$voice.bin")
    }

    /**
     * The model, the tokenizer and [voice] are all in [directory], and the files the catalogue knows are the right
     * size (a cheap check that a download finished; the hash is the full one).
     */
    @JvmStatic
    @JvmOverloads
    fun isInstalled(directory: File, voice: String, modelFile: String = DEFAULT_MODEL_FILE): Boolean {
        if (!isVoiceName(voice)) return false
        return isComplete(modelPath(directory, modelFile), findModel(modelFile)?.file) &&
            isComplete(tokenizerPath(directory), tokenizer) &&
            isComplete(voicePath(directory, voice), findVoice(voice)?.file)
    }

    /**
     * The files [voice] needs with [modelFile] that are missing from [directory] or the wrong size: what to
     * download. Empty when it is installed.
     *
     * @throws IllegalArgumentException The model or voice is not in the catalogue.
     */
    @JvmStatic
    @JvmOverloads
    fun missingFiles(directory: File, voice: String, modelFile: String = DEFAULT_MODEL_FILE): List<KokoroFile> {
        val model = requireNotNull(findModel(modelFile)) { "$modelFile is not one of Kokoro's models." }
        val voiceFile = requireNotNull(findVoice(voice)) { "$voice is not one of Kokoro's voices." }
        return listOf(model.file, tokenizer, voiceFile.file)
            .filter { !isComplete(File(directory, it.relativePath.replace('/', File.separatorChar)), it) }
    }

    internal fun isVoiceName(voice: String?): Boolean =
        !voice.isNullOrEmpty() && voice.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '_' || it == '-' }

    internal fun checkVoiceName(voice: String) {
        require(isVoiceName(voice)) { "\"$voice\" is not a voice name (letters, digits, '_' and '-')." }
    }

    private fun isComplete(file: File, known: KokoroFile?): Boolean =
        file.isFile && (known == null || file.length() == known.sizeBytes)

    private fun model(id: String, name: String, description: String, size: Long, sha256: String) =
        KokoroModel(id, name, description, KokoroFile("$id.onnx", size, "${BASE}onnx/$id.onnx", sha256))

    private fun voice(name: String, size: Long, sha256: String) =
        KokoroVoice(name, languageOf(name), name.length > 1 && name[1] == 'f',
            KokoroFile("$VOICES_FOLDER/$name.bin", size, "$BASE$VOICES_FOLDER/$name.bin", sha256))
}
