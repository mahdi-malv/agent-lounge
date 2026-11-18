package wtf.mahdi.agentloungecompanion.ui.components

import android.provider.Settings
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import wtf.mahdi.agentloungecompanion.R
import wtf.mahdi.agentloungecompanion.protocol.SessionState
import wtf.mahdi.agentloungecompanion.ui.theme.LoungeColors
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sin

/**
 * Agent Lounge mascot, same design as the Mac app: rounded critter with an antenna.
 * Body color = project. Face, bulb and badge = state. Animates in the draw phase only.
 */
@Composable
fun Avatar(
    state: SessionState,
    color: Color,
    modifier: Modifier = Modifier,
    phaseSeconds: Float = 0f,
) {
    val animated = state == SessionState.RUNNING || state == SessionState.NEEDS_INPUT
    val time = avatarTime(animated && !animationsOff())
    val label = stringResource(R.string.cd_avatar, stringResource(stateLabel(state)))
    Canvas(
        modifier = modifier
            .size(width = 40.dp, height = 47.dp)
            .semantics { contentDescription = label },
    ) {
        val t = time.value.let { if (it == 0f) 0f else it + phaseSeconds }
        scale(size.width / DESIGN_W, size.height / DESIGN_H, pivot = Offset.Zero) {
            AvatarPainter(state, color, t).paint(this)
        }
    }
}

fun stateLabel(state: SessionState): Int = when (state) {
    SessionState.RUNNING -> R.string.state_running
    SessionState.NEEDS_INPUT -> R.string.state_needs_input
    SessionState.IDLE -> R.string.state_done
    SessionState.ERROR -> R.string.state_error
}

@Composable
private fun avatarTime(animated: Boolean): State<Float> {
    if (!animated) return remember { androidx.compose.runtime.mutableFloatStateOf(0f) }
    val transition = rememberInfiniteTransition(label = "avatar")
    // 0.001 instead of 0: 0 means "still pose" in the painter.
    return transition.animateFloat(
        initialValue = 0.001f,
        targetValue = LOOP_SECONDS,
        animationSpec = infiniteRepeatable(tween((LOOP_SECONDS * 1000).toInt(), easing = LinearEasing), RepeatMode.Restart),
        label = "time",
    )
}

@Composable
private fun animationsOff(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

private const val DESIGN_W = 44f
private const val DESIGN_H = 52f
/** Long loop so the different sine periods do not visibly jump at the restart. */
private const val LOOP_SECONDS = 4.2f * 20

private val Ink = Color(0xFF211F2B)

private class AvatarPainter(val state: SessionState, color: Color, val time: Float) {
    private val base = if (state == SessionState.ERROR) lerp(color, Color.Gray, 0.5f) else color
    private val tint = LoungeColors.stateTint(state)
    private val dark = lerp(base, Color.Black, 0.28f)

    private val bob: Float get() = if (state == SessionState.RUNNING && time != 0f) sin(time * 3.2f) * 1.2f else 0f

    private val eyeOpenness: Float
        get() {
            if (time == 0f) return 1f
            val period = 4.2f
            val duration = 0.16f
            val t = time % period
            if (t >= duration) return 1f
            return max(0.12f, abs(t - duration / 2) / (duration / 2))
        }

    fun paint(scope: DrawScope) = with(scope) {
        for (x in listOf(12f, 24f)) {
            drawRoundRect(dark, Offset(x, 44f), Size(8f, 7f), CornerRadius(3.5f))
        }
        translate(top = bob) {
            drawAntenna()
            drawBody()
            drawFace()
        }
        if (state == SessionState.NEEDS_INPUT) drawBadge()
    }

    private fun DrawScope.drawAntenna() {
        drawLine(dark, Offset(22f, 13f), Offset(22f, 6.5f), strokeWidth = 2f, cap = StrokeCap.Round)
        val bulbColor = when (state) {
            SessionState.RUNNING -> tint.copy(alpha = if (time == 0f) 1f else 0.55f + 0.45f * (0.5f + 0.5f * sin(time * 4f)))
            SessionState.NEEDS_INPUT, SessionState.ERROR -> tint
            SessionState.IDLE -> lerp(base, Color.White, 0.45f)
        }
        drawCircle(bulbColor, radius = 3.5f, center = Offset(22f, 6f))
    }

    private fun DrawScope.drawBody() {
        drawRoundRect(
            brush = Brush.verticalGradient(listOf(lerp(base, Color.White, 0.22f), base), startY = 12f, endY = 48f),
            topLeft = Offset(2f, 12f),
            size = Size(40f, 36f),
            cornerRadius = CornerRadius(13f),
        )
        drawOval(Color.White.copy(alpha = 0.28f), Offset(8f, 15f), Size(10f, 5f))
    }

    private fun DrawScope.drawFace() {
        val eyes = listOf(Offset(15f, 27f), Offset(29f, 27f))
        val line = Stroke(width = 2f, cap = StrokeCap.Round)
        when (state) {
            SessionState.RUNNING -> {
                val look = if (time == 0f) 0f else sin(time * 1.3f) * 1.8f
                drawOpenEyes(eyes, Size(9f, 10.5f), Offset(look, 1f))
                drawLine(Ink, Offset(19.5f, 37f), Offset(24.5f, 37f), strokeWidth = 2f, cap = StrokeCap.Round)
            }
            SessionState.NEEDS_INPUT -> {
                drawOpenEyes(eyes, Size(10.5f, 12.5f), Offset(0f, -1.8f))
                drawOval(Ink, Offset(20f, 35f), Size(4f, 4.8f))
            }
            SessionState.IDLE -> {
                for (eye in eyes) {
                    drawPath(curve(Offset(eye.x - 4, eye.y + 1.5f), Offset(eye.x, eye.y - 4), Offset(eye.x + 4, eye.y + 1.5f)), Ink, style = line)
                }
                drawPath(curve(Offset(18.5f, 35.5f), Offset(22f, 39.5f), Offset(25.5f, 35.5f)), Ink, style = line)
                val blush = Color(1f, 0.45f, 0.55f, 0.45f)
                drawOval(blush, Offset(6f, 31.5f), Size(6f, 3.5f))
                drawOval(blush, Offset(32f, 31.5f), Size(6f, 3.5f))
            }
            SessionState.ERROR -> {
                for (eye in eyes) {
                    drawLine(Ink, Offset(eye.x - 3.2f, eye.y - 3.2f), Offset(eye.x + 3.2f, eye.y + 3.2f), 2.2f, StrokeCap.Round)
                    drawLine(Ink, Offset(eye.x + 3.2f, eye.y - 3.2f), Offset(eye.x - 3.2f, eye.y + 3.2f), 2.2f, StrokeCap.Round)
                }
                drawPath(curve(Offset(18.5f, 38.5f), Offset(22f, 34.5f), Offset(25.5f, 38.5f)), Ink, style = line)
            }
        }
    }

    private fun DrawScope.drawOpenEyes(centers: List<Offset>, size: Size, pupil: Offset) {
        val openness = eyeOpenness
        for (center in centers) {
            val height = size.height * openness
            drawOval(Color.White, Offset(center.x - size.width / 2, center.y - height / 2), Size(size.width, height))
            if (openness > 0.5f) drawCircle(Ink, radius = 2.6f, center = center + pupil)
        }
    }

    private fun DrawScope.drawBadge() {
        val pulse = if (time == 0f) 1f else 1f + 0.08f * sin(time * 5f)
        val radius = 6.5f * pulse
        val center = Offset(37f, 9f)
        drawCircle(tint, radius, center)
        drawCircle(Color.White.copy(alpha = 0.9f), radius, center, style = Stroke(1.2f))
        // "!" drawn as a bar and a dot (no text layout in the draw phase).
        drawLine(Color.White, Offset(37f, 5.6f), Offset(37f, 9.6f), strokeWidth = 2.2f, cap = StrokeCap.Round)
        drawCircle(Color.White, radius = 1.2f, center = Offset(37f, 12.4f))
    }

    private fun curve(start: Offset, control: Offset, end: Offset) = Path().apply {
        moveTo(start.x, start.y)
        quadraticTo(control.x, control.y, end.x, end.y)
    }
}

@Preview(showBackground = true)
@Composable
private fun AvatarPreview() {
    Row(modifier = Modifier.padding(16.dp)) {
        SessionState.entries.forEachIndexed { index, state ->
            Avatar(state = state, color = LoungeColors.project(index))
            Spacer(Modifier.width(12.dp))
        }
    }
}
