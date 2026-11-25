package wtf.mahdi.agentloungecompanion.ui.lounge

import androidx.compose.runtime.Immutable
import wtf.mahdi.agentloungecompanion.protocol.AgentKind
import wtf.mahdi.agentloungecompanion.protocol.AgentUsage
import wtf.mahdi.agentloungecompanion.protocol.LoungeProtocol
import kotlin.math.roundToInt

/** One agent row of the usage strip. */
@Immutable
data class UsageUi(
    val agent: String,
    val plan: String?,
    val problem: String?,
    val windows: List<WindowUi>,
) {
    @Immutable
    data class WindowUi(
        val label: String,
        /** 0..1 used. */
        val fraction: Float,
        /** "88% left". */
        val left: String,
        /** "2h 10m", null when unknown. */
        val resetsIn: String?,
        val level: Level,
    )

    enum class Level { OK, HIGH, CRITICAL }
}

object UsageFormat {
    fun toUi(usages: List<AgentUsage>, now: Long): List<UsageUi> = usages.map { usage ->
        UsageUi(
            agent = when (usage.agent) {
                AgentKind.CLAUDE -> "Claude"
                AgentKind.CODEX -> "Codex"
                AgentKind.ANTIGRAVITY -> "Antigravity"
            },
            plan = usage.plan?.replaceFirstChar { it.uppercase() },
            problem = usage.problem,
            windows = usage.windows.take(2).map { window ->
                val used = window.usedPercent.coerceIn(0.0, 100.0)
                val resetsAt = LoungeProtocol.epochMillis(window.resetsAt)
                UsageUi.WindowUi(
                    label = window.label,
                    fraction = (used / 100).toFloat(),
                    left = "${(100 - used).roundToInt()}% left",
                    resetsIn = resetsAt.takeIf { it > 0 }?.let { resetsIn(it - now) },
                    level = when {
                        used >= 90 -> UsageUi.Level.CRITICAL
                        used >= 70 -> UsageUi.Level.HIGH
                        else -> UsageUi.Level.OK
                    },
                )
            },
        )
    }

    /** "now", "45m", "2h 10m", "3d 4h". */
    fun resetsIn(millis: Long): String {
        val minutes = millis / 60_000
        if (minutes < 1) return "now"
        val hours = minutes / 60
        val days = hours / 24
        return when {
            days > 0 -> if (hours % 24 > 0) "${days}d ${hours % 24}h" else "${days}d"
            hours > 0 -> if (minutes % 60 > 0) "${hours}h ${minutes % 60}m" else "${hours}h"
            else -> "${minutes}m"
        }
    }
}

