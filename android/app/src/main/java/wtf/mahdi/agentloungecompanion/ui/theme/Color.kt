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
}
