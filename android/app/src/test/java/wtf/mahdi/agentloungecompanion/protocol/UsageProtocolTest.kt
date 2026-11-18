package wtf.mahdi.agentloungecompanion.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import wtf.mahdi.agentloungecompanion.ui.lounge.UsageFormat
import wtf.mahdi.agentloungecompanion.ui.lounge.UsageUi

class UsageProtocolTest {

    /** Shape of the Mac `ServerMessage` with `usage` (sorted keys, ISO dates without fractions). */
    private val text = """
        {"sentAt":"2026-11-18T12:00:00Z","sessions":[],"type":"snapshot","usage":[
        {"agent":"claude","plan":"max","updatedAt":"2026-11-18T12:00:00Z","windows":[
          {"label":"5h","resetsAt":"2026-11-18T14:10:00Z","usedPercent":12},
          {"label":"7d","resetsAt":"2026-11-21T16:00:00Z","usedPercent":92.5}]},
        {"agent":"codex","problem":"Not signed in","updatedAt":"2026-11-18T12:00:00Z","windows":[]}],"v":2}
    """.trimIndent()

    @Test
    fun snapshotWithUsage() {
        val snapshot = LoungeProtocol.parse(text) as Incoming.Snapshot
        assertEquals(listOf(AgentKind.CLAUDE, AgentKind.CODEX), snapshot.usage.map { it.agent })
        assertEquals(92.5, snapshot.usage[0].windows[1].usedPercent, 0.0)
        assertEquals("Not signed in", snapshot.usage[1].problem)
    }

    @Test
    fun snapshotWithoutUsage() {
        val snapshot = LoungeProtocol.parse("""{"type":"snapshot","sessions":[]}""") as Incoming.Snapshot
        assertTrue(snapshot.usage.isEmpty())
    }

    @Test
    fun usageRows() {
        val snapshot = LoungeProtocol.parse(text) as Incoming.Snapshot
        val now = LoungeProtocol.epochMillis("2026-11-18T12:00:00Z")
        val rows = UsageFormat.toUi(snapshot.usage, now)
        val claude = rows[0]
        assertEquals("Claude", claude.agent)
        assertEquals("Max", claude.plan)
        assertEquals(listOf("88% left", "8% left"), claude.windows.map { it.left })
        assertEquals(listOf("2h 10m", "3d 4h"), claude.windows.map { it.resetsIn })
        assertEquals(listOf(UsageUi.Level.OK, UsageUi.Level.CRITICAL), claude.windows.map { it.level })
        assertEquals("Not signed in", rows[1].problem)
    }

    @Test
    fun resetsIn() {
        assertEquals("now", UsageFormat.resetsIn(30_000))
        assertEquals("45m", UsageFormat.resetsIn(45 * 60_000L))
        assertEquals("2h", UsageFormat.resetsIn(120 * 60_000L))
    }
}
