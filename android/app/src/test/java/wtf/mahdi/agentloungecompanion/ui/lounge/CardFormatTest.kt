package wtf.mahdi.agentloungecompanion.ui.lounge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import wtf.mahdi.agentloungecompanion.protocol.RemoteCard
import wtf.mahdi.agentloungecompanion.protocol.SessionState
import wtf.mahdi.agentloungecompanion.protocol.TaskStatus

class CardFormatTest {

    @Test
    fun durations() {
        assertEquals("0s", CardFormat.duration(-5))
        assertEquals("45s", CardFormat.duration(45_000))
        assertEquals("12m", CardFormat.duration(12 * 60_000L + 5_000))
        assertEquals("1h 05m", CardFormat.duration(65 * 60_000L))
        assertEquals("2d 3h", CardFormat.duration((2 * 24 + 3) * 3_600_000L))
    }

    @Test
    fun tokens() {
        assertEquals("850", CardFormat.tokens(850))
        assertEquals("24k", CardFormat.tokens(24_000))
        assertEquals("101k", CardFormat.tokens(101_461))
        assertEquals("1M", CardFormat.tokens(1_000_000))
        assertEquals("1.5M", CardFormat.tokens(1_500_000))
    }

    /** Mac `ProjectPalette.fnv1a` gives the same values (64-bit FNV-1a over UTF-8). */
    @Test
    fun fnvMatchesReference() {
        assertEquals(0xcbf29ce484222325uL, CardFormat.fnv1a(""))
        assertEquals(0xaf63dc4c8601ec8cuL, CardFormat.fnv1a("a"))
        assertEquals(0x85944171f73967e8uL, CardFormat.fnv1a("foobar"))
    }

    @Test
    fun sortByUrgency() {
        val cards = listOf(
            RemoteCard(id = "idle", state = SessionState.IDLE),
            RemoteCard(id = "run", state = SessionState.RUNNING),
            RemoteCard(id = "ask", state = SessionState.NEEDS_INPUT),
            RemoteCard(id = "err", state = SessionState.ERROR),
        )
        assertEquals(listOf("ask", "err", "run", "idle"), CardFormat.sorted(cards).map { it.id })
    }

    @Test
    fun toUi() {
        val card = RemoteCard(
            id = "claude:x",
            title = "",
            project = "app",
            model = "opus",
            effort = "high",
            startedAt = "1970-01-01T00:00:01Z",
            lastEventAt = "1970-01-01T00:01:01Z",
            context = RemoteCard.Context(usedTokens = 50_000, limitTokens = 200_000),
            tasks = listOf(
                RemoteCard.TaskItem("Write", "Writing", TaskStatus.COMPLETED),
                RemoteCard.TaskItem("Test", "Testing", TaskStatus.IN_PROGRESS),
            ),
            lastMessage = "  ",
        )
        val ui = CardFormat.toUi(card, nowMillis = 3_601_000)
        assertEquals("app", ui.title)
        assertEquals("1h 00m", ui.elapsed)
        assertEquals("59m", ui.lastEventAgo)
        assertEquals("opus · high", ui.modelLine)
        assertEquals(CardUi.ContextUi("50k / 200k", 0.25f), ui.context)
        assertEquals(listOf("Write", "Testing"), ui.tasks.map { it.text })
        assertNull(ui.lastMessage)
        assertEquals((CardFormat.fnv1a("app") % 9uL).toInt(), ui.colorIndex)
    }

    @Test
    fun promptFieldOnlyForPromptableCards() {
        val ghostty = RemoteCard(id = "a", canPrompt = true)
        val other = RemoteCard(id = "b")
        assertEquals(CardUi.PromptUi("hi", isSending = true), CardFormat.toUi(ghostty, 0, drafts = mapOf("a" to "hi"), sendingPrompts = setOf("a")).prompt)
        assertNull(CardFormat.toUi(other, 0, drafts = mapOf("b" to "hi")).prompt)
        assertEquals(false, CardUi.PromptUi(" ", isSending = false).canSend)
    }
}
