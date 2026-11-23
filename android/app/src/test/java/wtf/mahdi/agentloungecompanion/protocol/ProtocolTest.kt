package wtf.mahdi.agentloungecompanion.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {

    @Test
    fun clientMessages() {
        assertEquals(
            """{"type":"pair","v":2,"device":"Pixel","pub":"AQI=","proof":"AwQ="}""",
            LoungeProtocol.pair("Pixel", byteArrayOf(1, 2), byteArrayOf(3, 4)),
        )
        assertEquals("""{"type":"hello","v":2,"deviceId":"d","nonce":"BQ=="}""", LoungeProtocol.hello("d", byteArrayOf(5)))
        assertEquals("""{"type":"auth"}""", LoungeProtocol.auth())
        assertEquals("""{"type":"prompt","cardId":"c","text":"go"}""", LoungeProtocol.prompt("c", "go"))
    }

    @Test
    fun handshakeMessages() {
        val paired = LoungeProtocol.parse("""{"type":"paired","pub":"AQI=","box":"AwQ=","v":2}""") as Incoming.Paired
        assertTrue(paired.publicKey.contentEquals(byteArrayOf(1, 2)) && paired.box.contentEquals(byteArrayOf(3, 4)))
        val challenge = LoungeProtocol.parse("""{"type":"challenge","nonce":"BQ==","v":2}""") as Incoming.Challenge
        assertTrue(challenge.nonce.contentEquals(byteArrayOf(5)))
        val welcome = LoungeProtocol.parse("""{"deviceId":"D","server":"M","serverId":"S","type":"welcome","v":2}""")
        assertEquals(Incoming.Welcome("D", "M", "S"), welcome)
        assertEquals(
            Incoming.Welcome("D", "M", "S", listOf("192.168.1.5", "100.69.105.56")),
            LoungeProtocol.parse("""{"deviceId":"D","server":"M","serverId":"S","addresses":["192.168.1.5","100.69.105.56"],"type":"welcome","v":2}"""),
        )
        assertEquals(Incoming.Result("c", false, "no"), LoungeProtocol.parse("""{"type":"result","cardId":"c","ok":false,"reason":"no"}"""))
        assertEquals(
            PairedBox("AQID", "d1", "Mac", "s1"),
            LoungeProtocol.parseBox("""{"deviceId":"d1","secret":"AQID","server":"Mac","serverId":"s1"}"""),
        )
    }

    /** Shape as sent by the Mac app (sorted keys, ISO dates, escaped slashes). */
    @Test
    fun snapshot() {
        val text = """
            {"sentAt":"2026-11-18T01:52:50Z","sessions":[{"agent":"codex","context":{"limitTokens":258000,"usedTokens":24000},
            "cwd":"\/Users\/u\/code\/app","effort":"high","host":"Codex · Ghostty","id":"codex:t1",
            "lastEventAt":"2026-11-18T01:52:40Z","lastMessage":"Done.","model":"gpt-5","progress":{"done":1,"total":2,"label":"Testing"},
            "project":"app","startedAt":"2026-11-18T01:40:00Z","state":"needsInput","subagentCount":2,"subtitle":"Allow Bash?",
            "tasks":[{"activeForm":"Writing","status":"completed","subject":"Write"},{"status":"inProgress","subject":"Test"}],
            "title":"app · Fix","futureField":true}],"type":"snapshot","v":1}
        """.trimIndent()
        val snapshot = LoungeProtocol.parse(text) as Incoming.Snapshot
        val card = snapshot.sessions.single()
        assertEquals(AgentKind.CODEX, card.agent)
        assertEquals(SessionState.NEEDS_INPUT, card.state)
        assertEquals("/Users/u/code/app", card.cwd)
        assertEquals(RemoteCard.Progress(1, 2, "Testing"), card.progress)
        assertEquals(TaskStatus.IN_PROGRESS, card.tasks[1].status)
        assertEquals(RemoteCard.Context(24000, 258000), card.context)
        assertEquals(100_000L, LoungeProtocol.epochMillis("1970-01-01T00:01:40Z"))
        assertTrue(card.attention == null && card.permissionMode == null)
    }

    @Test
    fun unknownEnumFallsBackToDefault() {
        val snapshot = LoungeProtocol.parse(
            """{"type":"snapshot","sessions":[{"id":"x","state":"sleeping","agent":"gemini"}]}""",
        ) as Incoming.Snapshot
        assertEquals(SessionState.RUNNING, snapshot.sessions.single().state)
        assertEquals(AgentKind.CLAUDE, snapshot.sessions.single().agent)
    }

    @Test
    fun alertsAndErrors() {
        val alert = LoungeProtocol.parse(
            """{"alert":{"cardId":"claude:s","kind":"done","message":"All done.","title":"app"},"type":"alert","v":1}""",
        )
        assertEquals(Incoming.Alert(RemoteAlert(AlertKind.DONE, "claude:s", "app", "All done.")), alert)
        val revoked = LoungeProtocol.parse("""{"error":"revoked","type":"error","v":1}""") as Incoming.Error
        assertEquals(ErrorCode.REVOKED, revoked.code)
        assertTrue(revoked.code.needsNewPairing)
        assertFalse(ErrorCode.AUTH_TIMEOUT.needsNewPairing)
        assertEquals(ErrorCode.OTHER, (LoungeProtocol.parse("""{"type":"error","error":"new"}""") as Incoming.Error).code)
        assertEquals(Incoming.Unknown, LoungeProtocol.parse("not json"))
        assertEquals(Incoming.Unknown, LoungeProtocol.parse("""{"type":"later"}"""))
        assertEquals(Incoming.Unknown, LoungeProtocol.parse("""{"type":"paired"}"""))
        assertEquals(Incoming.Unknown, LoungeProtocol.parse("""{"type":"challenge"}"""))
    }

    @Test
    fun approvals() {
        assertEquals("""{"type":"decide","requestId":"r1","allow":false}""", LoungeProtocol.decide("r1", false))
        val alert = LoungeProtocol.parse(
            """{"type":"alert","alert":{"kind":"needsInput","cardId":"c","title":"t","message":"m","approval":{"id":"r1","tool":"Bash","title":"Run","detail":"rm x"}}}""",
        ) as Incoming.Alert
        assertEquals(RemoteApproval("r1", "Bash", "Run", "rm x"), alert.alert.approval)
    }

    @Test
    fun badDatesGiveZero() {
        assertEquals(0L, LoungeProtocol.epochMillis(null))
        assertEquals(0L, LoungeProtocol.epochMillis("yesterday"))
    }
}
