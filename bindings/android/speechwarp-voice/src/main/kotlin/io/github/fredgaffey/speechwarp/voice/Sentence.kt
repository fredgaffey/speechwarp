package io.github.fredgaffey.speechwarp.voice

import java.text.BreakIterator
import java.util.Locale

/**
 * A sentence of a text: where it starts, how long it is (both in UTF-16 units, as String indices are), and its text.
 */
data class Sentence(val start: Int, val length: Int, val text: String) {
    /** The index just past the sentence. */
    val end: Int get() = start + length

    companion object {
        private const val MAX_SENTENCE = 400

        /**
         * The sentences of [text], by the platform's sentence rules for [locale] (ICU on Android). Any longer than 400
         * characters are cut at the last comma, semicolon or colon before that, or else the last space, so that no
         * voice stalls on one enormous sentence. Stretches of only white space are left out.
         */
        @JvmStatic
        @JvmOverloads
        fun split(text: String, locale: Locale = Locale.getDefault()): List<Sentence> {
            val result = ArrayList<Sentence>()
            val iterator = BreakIterator.getSentenceInstance(locale)
            iterator.setText(text)
            var from = iterator.first()
            var to = iterator.next()
            while (to != BreakIterator.DONE) {
                var start = from
                val end = to
                while (end - start > MAX_SENTENCE) {
                    val limit = start + MAX_SENTENCE
                    val mark = text.lastIndexOfAny(charArrayOf(',', ';', ':'), limit - 1)
                    val space = text.lastIndexOf(' ', limit - 1)
                    val cut = when {
                        mark > start -> mark + 1
                        space > start -> space
                        else -> limit
                    }
                    result.add(Sentence(start, cut - start, text.substring(start, cut)))
                    start = cut
                }
                if (text.substring(start, end).isNotBlank()) {
                    result.add(Sentence(start, end - start, text.substring(start, end)))
                }
                from = to
                to = iterator.next()
            }
            return result
        }
    }
}
