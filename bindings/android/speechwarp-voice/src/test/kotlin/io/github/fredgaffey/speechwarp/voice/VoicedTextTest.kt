package io.github.fredgaffey.speechwarp.voice

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.math.abs

class VoicedTextTest {
    @get:Rule
    val folder = TemporaryFolder()

    /** Reads until the end; every chunk's samples go to [each], with the character position after it. */
    private fun readAll(reader: VoicedText, chunk: Int = 1024, each: (FloatArray, Int, Int) -> Unit = { _, _, _ -> }): Long {
        val buffer = FloatArray(chunk)
        var total = 0L
        val end = System.currentTimeMillis() + 30_000
        while (!reader.isFinished) {
            check(System.currentTimeMillis() < end) { "the reader never finished" }
            val frames = reader.read(buffer)
            if (frames > 0) {
                each(buffer, frames, reader.characterPosition)
                total += frames
            } else {
                Thread.sleep(1)
            }
        }
        return total
    }

    @Test
    fun passesTheVoicesAudioThroughUnchanged() {
        val text = sentencesText(12)
        val voice = FakeVoice("fake:a")
        VoicedText(text, voice, VoicedTextOptions(speedUp = false)).use { reader ->
            assertFalse(reader.speedsUp)
            assertEquals(16000, reader.sampleRate)
            val total = readAll(reader) { samples, frames, _ ->
                for (i in 0 until frames) assertEquals(0.5f, samples[i], 0f)
            }
            val expected = reader.sentences.sumOf { it.text.trim().length * 160L }
            assertEquals(expected, total)
            assertEquals(text.length, reader.characterPosition)
            assertTrue(reader.isFinished)
            assertEquals(12, reader.sentences.size)
        }
    }

    @Test
    fun positionNeverGoesBackwardsAndReachesTheEnd() {
        val text = sentencesText(20)
        VoicedText(text, FakeVoice("fake:a")).use { reader ->
            reader.speed = 2.5f
            var last = -1
            var lastTime = -1.0
            var frame = 0L
            readAll(reader, 777) { _, frames, at ->
                assertTrue("position went back from $last to $at", at >= last)
                last = at
                frame += frames
                val time = reader.timeAt(frame)
                assertTrue("time went back from $lastTime to $time", time >= lastTime - 1e-9)
                lastTime = time
            }
            assertEquals(text.length, reader.characterPosition)
            assertEquals(reader.duration, reader.position, 1e-9)
        }
    }

    @Test
    fun speedsUp() {
        val text = sentencesText(30)
        val total1 = VoicedText(text, FakeVoice("fake:a")).use { readAll(it) }
        val total3 = VoicedText(text, FakeVoice("fake:a")).use {
            it.speed = 3f
            readAll(it)
        }
        val ratio = total1.toDouble() / total3
        assertTrue("speed-up ratio $ratio", ratio in 2.5..3.5)
    }

    @Test
    fun resamplesAVoiceAtAnotherRate() {
        val text = sentencesText(3)
        VoicedText(text, FakeVoice("fake:a", sampleRate = 8000, framesPerCharacter = 80),
            VoicedTextOptions(sampleRate = 16000, speedUp = false)).use { reader ->
            val expected = reader.sentences.sumOf { it.text.trim().length * 160L }
            assertEquals(expected.toDouble(), readAll(reader).toDouble(), 3.0)
        }
    }

    @Test
    fun aNewVoiceTakesOverFromTheNextSentenceAndTheOldOneIsClosedOnTheReadersThread() {
        val text = sentencesText(30)
        val first = FakeVoice("fake:a", level = 0.5f)
        val second = FakeVoice("fake:b", level = -0.5f)
        VoicedText(text, first, VoicedTextOptions(speedUp = false)).use { reader ->
            var changed = false
            var sawNew = false
            var readSoFar = 0L
            readAll(reader, 500) { samples, frames, _ ->
                for (i in 0 until frames) {
                    if (samples[i] < 0) sawNew = true
                    else assertFalse("the old voice came back after the new one", sawNew)
                }
                readSoFar += frames
                if (!changed && readSoFar > 20_000) {
                    reader.setVoice(second)
                    changed = true
                    assertEquals("fake:b", reader.voiceId)
                }
            }
            assertTrue(sawNew)
            waitFor { first.closed }
            assertNotNull(first.closedOn)
            assertNotSame(Thread.currentThread(), first.closedOn)
            assertFalse(second.closed)
        }
        waitFor { second.closed }
        assertNotSame(Thread.currentThread(), second.closedOn)
    }

    @Test
    fun aFactoryMakesVoicesOnTheReadersThread() {
        val text = sentencesText(30)
        val made = mutableListOf<Pair<String, Thread>>()
        val factory = VoiceFactory { id ->
            synchronized(made) { made.add(id to Thread.currentThread()) }
            if (id == "fake:broken") throw IllegalArgumentException("no such voice")
            FakeVoice(id, level = if (id == "fake:b") -0.5f else 0.5f)
        }
        VoicedText(text, "fake:a", factory, VoicedTextOptions(speedUp = false)).use { reader ->
            assertEquals(Thread.currentThread(), made.single().second)
            reader.setVoice("fake:broken")
            waitFor { reader.lastError is IllegalArgumentException }
            assertEquals("fake:a", reader.voiceId)
            reader.setVoice("fake:b")
            var sawNew = false
            readAll(reader) { samples, frames, _ -> if ((0 until frames).any { samples[it] < 0 }) sawNew = true }
            assertTrue(sawNew)
            assertEquals("fake:b", reader.voiceId)
            synchronized(made) {
                assertEquals(listOf("fake:a", "fake:broken", "fake:b"), made.map { it.first })
                assertTrue(made.drop(1).all { it.second !== Thread.currentThread() })
            }
        }
    }

    @Test
    fun seeksByCharacterAndByTime() {
        val text = sentencesText(40)
        VoicedText(text, FakeVoice("fake:a"), VoicedTextOptions(speedUp = false, secondsPerCharacter = 0.05)).use { reader ->
            val target = reader.sentences[25]
            val frame = reader.seekToCharacter(target.start + 3)
            assertEquals(Math.round(target.start * 0.05 * 16000), frame)
            assertEquals(25, reader.sentenceIndex)
            assertEquals(target.start, reader.characterPosition)
            assertEquals(target.start * 0.05, reader.timeAt(frame), 1e-9)

            // Reading on from the seek: frames count from the frame it returned.
            val buffer = FloatArray(400)
            var read = 0L
            while (read < 400) {
                val n = reader.read(buffer)
                if (n == 0) Thread.sleep(1)
                read += n
            }
            assertTrue(reader.characterPosition > target.start)
            assertTrue(reader.timeAt(frame + read) > target.start * 0.05)

            // Back to an earlier place by time.
            val earlier = reader.sentences[3]
            val back = reader.seekToTime(earlier.start * 0.05 + 0.01)
            assertEquals(Math.round(earlier.start * 0.05 * 16000), back)
            assertEquals(3, reader.sentenceIndex)
            val total = readAll(reader)
            val expected = reader.sentences.drop(3).sumOf { it.text.trim().length * 160L }
            assertEquals(expected, total)
            assertEquals(text.length, reader.characterPosition)
        }
    }

    @Test
    fun timelineIsCharactersAtTheirPace() {
        val text = sentencesText(5)
        VoicedText(text, FakeVoice("fake:a"), VoicedTextOptions(secondsPerCharacter = 0.1)).use { reader ->
            assertEquals(text.length * 0.1, reader.duration, 1e-9)
            assertEquals(0.0, reader.timeAt(0), 1e-9)
            // Past the end is the start of the last sentence.
            val last = reader.sentences.last()
            assertEquals(last.start * 0.1, reader.seekToTime(1e9).toDouble() / reader.sampleRate, 1.0 / reader.sampleRate)
            assertEquals(4, reader.sentenceIndex)
        }
    }

    @Test
    fun aSentenceThatFailsIsSkippedAndReported() {
        val text = "First one here. This one breaks. Last one here."
        VoicedText(text, FakeVoice("fake:a", failOn = "breaks"), VoicedTextOptions(speedUp = false)).use { reader ->
            val total = readAll(reader)
            assertEquals(("First one here.".length + "Last one here.".length) * 160L, total)
            assertTrue(reader.lastError is IllegalStateException)
        }
    }

    @Test
    fun readsShorts() {
        VoicedText(sentencesText(2), FakeVoice("fake:a"), VoicedTextOptions(speedUp = false)).use { reader ->
            val buffer = ShortArray(256)
            waitFor { reader.read(buffer, 6, 250) > 0 }
            assertEquals(Math.round(0.5f * 32767).toShort(), buffer[6])
            assertEquals(0.toShort(), buffer[5])
        }
    }

    @Test
    fun readsNothingWhileWaitingAndSaysSo() {
        val slow = FakeVoice("fake:slow", delayMillis = 300)
        VoicedText(sentencesText(3), slow, VoicedTextOptions(speedUp = false)).use { reader ->
            assertEquals(0, reader.read(FloatArray(100)))
            assertTrue(reader.isWaiting)
            assertFalse(reader.isFinished)
        }
    }

    @Test
    fun aSlowVoiceIsKeptOnDiskAndReadFromThereNextTime() {
        val text = sentencesText(50) // two blocks: 40 and 10
        val directory = folder.newFolder("cache")
        val options = VoicedTextOptions(speedUp = false, cacheDirectory = directory)
        val first = FakeVoice("fake:slow/1.5", keepsSpoken = true, delayMillis = 2)
        val firstAudio = ArrayList<Float>()
        VoicedText(text, first, options, RawCodec).use { reader ->
            readAll(reader) { samples, frames, _ -> for (i in 0 until frames) firstAudio.add(samples[i]) }
        }
        val cache = VoiceCache(text, "fake:slow/1.5", directory, RawCodec)
        waitFor { cache.has(0) && cache.has(1) }
        assertTrue(cache.directory.path.endsWith("fake-slow-1.5"))
        assertEquals(50, first.spoken.get())

        val second = FakeVoice("fake:slow/1.5", keepsSpoken = true, delayMillis = 200)
        val secondAudio = ArrayList<Float>()
        VoicedText(text, second, options, RawCodec).use { reader ->
            readAll(reader) { samples, frames, _ -> for (i in 0 until frames) secondAudio.add(samples[i]) }
        }
        assertEquals(0, second.spoken.get())
        assertEquals(firstAudio, secondAudio)

        // Another voice id does not share it.
        val third = FakeVoice("fake:slow/2", keepsSpoken = true)
        VoicedText(text, third, options, RawCodec).use { readAll(it) }
        assertEquals(50, third.spoken.get())
    }

    @Test
    fun aFastVoiceIsNotKept() {
        val directory = folder.newFolder("cache")
        val text = sentencesText(3)
        VoicedText(text, FakeVoice("fake:fast"), VoicedTextOptions(speedUp = false, cacheDirectory = directory), RawCodec)
            .use { readAll(it) }
        assertEquals(0, directory.listFiles()!!.size)
    }

    @Test
    fun speaksAheadToDiskWhenAllowed() {
        val text = sentencesText(90) // three blocks
        val directory = folder.newFolder("cache")
        val voice = FakeVoice("fake:slow", keepsSpoken = true, framesPerCharacter = 16)
        val options = VoicedTextOptions(speedUp = false, cacheDirectory = directory, keptLookahead = 1.0, speakAheadToDisk = { true })
        VoicedText(text, voice, options, RawCodec).use {
            val cache = VoiceCache(text, "fake:slow", directory, RawCodec)
            waitFor { (0 until 3).all { cache.has(it) } }
        }
        assertEquals(90, voice.spoken.get())
    }

    @Test
    fun aBlockShorterThanItShouldBeIsSpokenAgain() {
        val text = sentencesText(10)
        val directory = folder.newFolder("cache")
        val cache = VoiceCache(text, "fake:slow", directory, RawCodec)
        cache.save(0, listOf(FloatArray(10)), 16000) // one sentence of ten
        val voice = FakeVoice("fake:slow", keepsSpoken = true)
        VoicedText(text, voice, VoicedTextOptions(speedUp = false, cacheDirectory = directory), RawCodec).use {
            val total = readAll(it)
            // The sentence that is there is used; the block is dropped and the rest spoken.
            assertEquals(10 + it.sentences.drop(1).sumOf { s -> s.text.trim().length * 160L }, total)
        }
        assertEquals(9, voice.spoken.get())
        assertFalse(cache.has(0))
    }

    @Test
    fun closeIsQuickAndStopsReading() {
        val voice = FakeVoice("fake:slow", delayMillis = 500)
        val reader = VoicedText(sentencesText(5), voice)
        Thread.sleep(50)
        val started = System.nanoTime()
        reader.close()
        assertTrue((System.nanoTime() - started) / 1e6 < 100)
        assertEquals(0, reader.read(FloatArray(10)))
        waitFor { voice.closed }
        assertEquals(1f, reader.speed)
        assertTrue(abs(reader.position) >= 0)
    }
}
