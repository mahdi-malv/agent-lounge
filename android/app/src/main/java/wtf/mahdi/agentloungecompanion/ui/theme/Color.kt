package wtf.mahdi.agentloungecompanion.ui.theme

import androidx.compose.ui.graphics.Color
import wtf.mahdi.agentloungecompanion.protocol.SessionState

val Purple80 = Color(0xFFD0BCFF)
val PurpleGrey80 = Color(0xFFCCC2DC)
val Pink80 = Color(0xFFEFB8C8)

val Purple40 = Color(0xFF6650a4)
val PurpleGrey40 = Color(0xFF625b71)
val Pink40 = Color(0xFF7D5260)

/** Agent Lounge colors, same values as the Mac app (`Theme.swift`). */
object LoungeColors {
    val Running = Color(0xFF34C759)
    val NeedsInput = Color(0xFFFF9500)
    val Idle = Color(0xFF8E8E93)
    val Error = Color(0xFFFF3B30)

    fun stateTint(state: SessionState): Color = when (state) {
        SessionState.RUNNING -> Running
        SessionState.NEEDS_INPUT -> NeedsInput
        SessionState.IDLE -> Idle
        SessionState.ERROR -> Error
    }

    /** Project palette (Mac `ProjectPalette.colors`), index from `CardFormat`. */
    private val projects = listOf(
        Color(0.38f, 0.56f, 0.95f), // blue
        Color(0.95f, 0.50f, 0.72f), // pink
        Color(0.97f, 0.68f, 0.40f), // peach
        Color(0.38f, 0.80f, 0.56f), // green
        Color(0.67f, 0.57f, 0.98f), // violet
        Color(0.27f, 0.79f, 0.79f), // teal
        Color(0.96f, 0.80f, 0.33f), // yellow
        Color(0.66f, 0.85f, 0.38f), // lime
        Color(0.36f, 0.72f, 0.97f), // sky
    )

    fun project(index: Int): Color = projects[index.mod(projects.size)]
}
