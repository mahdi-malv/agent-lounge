package wtf.mahdi.agentloungecompanion.ui.lounge

import wtf.mahdi.agentloungecompanion.protocol.LoungeProtocol
import wtf.mahdi.agentloungecompanion.protocol.RemoteCard
import wtf.mahdi.agentloungecompanion.protocol.SessionState
import wtf.mahdi.agentloungecompanion.protocol.TaskStatus

/** One card as the list shows it. Built by [CardFormat.toUi]; no logic in the composables. */
data class CardUi(
    val id: String,
    val title: String,
    val subtitle: String,
    val host: String,
    val state: SessionState,
    /** Index into the project palette (same color as on the Mac). */
    val colorIndex: Int,
    /** Animation offset in seconds, so avatars do not move in sync. */
    val phaseSeconds: Float,
    val progress: ProgressUi?,
    val elapsed: String,
    val lastEventAgo: String,
    val modelLine: String?,
    val gitBranch: String?,
    val cwd: String,
    val subagentCount: Int,
    val context: ContextUi?,
    val lastMessage: String?,
    val tasks: List<TaskUi>,
    /** Open permission request (Claude). */
    val approval: ApprovalUi? = null,
    val prompt: PromptUi? = null,
) {
    /** Prompt field, for Ghostty sessions. */
    data class PromptUi(val draft: String, val isSending: Boolean) {
        val canSend: Boolean get() = draft.isNotBlank() && !isSending
    }

    data class ApprovalUi(val id: String, val title: String, val detail: String?, val tool: String, val isSent: Boolean)

    data class ProgressUi(val done: Int, val total: Int, val label: String?) {
        val fraction: Float get() = if (total > 0) done.toFloat() / total else 0f
    }

    data class ContextUi(val text: String, val fraction: Float)

    data class TaskUi(val text: String, val status: TaskStatus)
}

object CardFormat {
    const val PALETTE_SIZE = 9

    fun toUi(
        card: RemoteCard,
        nowMillis: Long,
        sentDecisions: Set<String> = emptySet(),
        drafts: Map<String, String> = emptyMap(),
        sendingPrompts: Set<String> = emptySet(),
    ): CardUi {
        val started = LoungeProtocol.epochMillis(card.startedAt)
        val lastEvent = LoungeProtocol.epochMillis(card.lastEventAt)
        return CardUi(
            id = card.id,
            title = card.title.ifEmpty { card.project },
            subtitle = card.subtitle,
            host = card.host,
            state = card.state,
            colorIndex = (fnv1a(card.project) % PALETTE_SIZE.toULong()).toInt(),
            phaseSeconds = (fnv1a(card.id) % 1000uL).toFloat() / 97f,
            progress = card.progress?.let { CardUi.ProgressUi(it.done, it.total, it.label) },
            elapsed = if (started > 0) duration(nowMillis - started) else "",
            lastEventAgo = if (lastEvent > 0) duration(nowMillis - lastEvent) else "",
            modelLine = listOfNotNull(card.model, card.effort, card.permissionMode).joinToString(" · ").ifEmpty { null },
            gitBranch = card.gitBranch,
            cwd = card.cwd,
            subagentCount = card.subagentCount,
            context = card.context?.takeIf { it.limitTokens > 0 }?.let {
                CardUi.ContextUi(
                    text = "${tokens(it.usedTokens)} / ${tokens(it.limitTokens)}",
                    fraction = (it.usedTokens.toFloat() / it.limitTokens).coerceIn(0f, 1f),
                )
            },
            lastMessage = card.lastMessage?.takeIf { it.isNotBlank() },
            prompt = if (card.canPrompt) CardUi.PromptUi(drafts[card.id].orEmpty(), card.id in sendingPrompts) else null,
            approval = card.approval?.let {
                CardUi.ApprovalUi(it.id, it.title.ifEmpty { it.tool }, it.detail, it.tool, isSent = it.id in sentDecisions)
            },
            tasks = card.tasks.map { CardUi.TaskUi(it.activeForm?.takeIf { _ -> it.status == TaskStatus.IN_PROGRESS } ?: it.subject, it.status) },
        )
    }

    /** Most urgent first: needs input, error, running, done. Stable within a state. */
    fun sorted(cards: List<RemoteCard>): List<RemoteCard> = cards.sortedBy { urgencyRank(it.state) }

    fun urgencyRank(state: SessionState): Int = when (state) {
        SessionState.NEEDS_INPUT -> 0
        SessionState.ERROR -> 1
        SessionState.RUNNING -> 2
        SessionState.IDLE -> 3
    }

    /** "45s", "12m", "1h 05m", "2d 3h". */
    fun duration(millis: Long): String {
        val seconds = (millis / 1000).coerceAtLeast(0)
        return when {
            seconds < 60 -> "${seconds}s"
            seconds < 3600 -> "${seconds / 60}m"
            seconds < 86_400 -> "%dh %02dm".format(seconds / 3600, (seconds % 3600) / 60)
            else -> "${seconds / 86_400}d ${(seconds % 86_400) / 3600}h"
        }
    }

    /** 24000 → "24k", 1000000 → "1M", 850 → "850". */
    fun tokens(count: Int): String = when {
        count >= 1_000_000 && count % 1_000_000 == 0 -> "${count / 1_000_000}M"
        count >= 1_000_000 -> "%.1fM".format(count / 1_000_000.0)
        count >= 1_000 -> "${count / 1_000}k"
        else -> count.toString()
    }

    /** Same hash as the Mac app (`ProjectPalette`), so colors match. */
    fun fnv1a(text: String): ULong {
        var hash = 0xcbf29ce484222325uL
        for (byte in text.encodeToByteArray()) {
            hash = hash xor byte.toUByte().toULong()
            hash *= 0x100000001b3uL
        }
        return hash
    }
}
