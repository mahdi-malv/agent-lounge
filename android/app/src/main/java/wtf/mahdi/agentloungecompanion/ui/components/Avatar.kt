package wtf.mahdi.agentloungecompanion.ui.components

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
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
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Agent Lounge avatar: a planet, same drawing as the Mac app (`AvatarView.swift`).
 * Running subagents orbit it as moons. Animates in the draw phase only.
 *
 * - running: the planet turns and floats, moons orbit, lava pulses.
 * - needs input: the planet rocks, orange glow, pulsing "!" badge.
 * - done: the sun shines from behind the planet.
 * - error: eclipse, a shadow covers half of the planet.
 */
@Composable
fun Avatar(
    state: SessionState,
    look: PlanetLook,
    modifier: Modifier = Modifier,
    moons: List<String> = emptyList(),
    phaseSeconds: Float = 0f,
) {
    val animated = state == SessionState.RUNNING || state == SessionState.NEEDS_INPUT
    val time = avatarClock(animated && !animationsOff())
    val moonLooks = remember(moons) { moons.take(MAX_MOONS).map(MoonLook::make) }
    val label = stringResource(R.string.cd_avatar, stringResource(stateLabel(state)))
    Canvas(
        modifier = modifier
            .size(52.dp)
            .semantics { contentDescription = label },
    ) {
        val t = time.value.let { if (it == 0.0) 0.0 else it + phaseSeconds }
        scale(size.width / DESIGN, size.height / DESIGN, pivot = Offset.Zero) {
            PlanetPainter(state, look, moonLooks, t).paint(this)
        }
    }
}

/** A subagent's moon, for its row under the card. Turns while the card runs. */
@Composable
fun MoonAvatar(name: String, animated: Boolean, modifier: Modifier = Modifier, phaseSeconds: Float = 0f) {
    val look = remember(name) { MoonLook.make(name) }
    val time = avatarClock(animated && !animationsOff())
    Canvas(modifier.size(22.dp)) {
        val t = time.value.let { if (it == 0.0) 0.0 else it + phaseSeconds }
        scale(size.width / MOON_DESIGN, size.height / MOON_DESIGN, pivot = Offset.Zero) {
            translate(11f, 11f) {
                val r = 9.0
                clipPath(ovalPath(-r, -r, r * 2, r * 2)) {
                    fillGlobe(r, look.palette)
                    fillSpots(look.craters, r, if (t == 0.0) 0.0 else t / 8)
                    shadeGlobe(r)
                }
            }
        }
    }
}

fun stateLabel(state: SessionState): Int = when (state) {
    SessionState.RUNNING -> R.string.state_running
    SessionState.NEEDS_INPUT -> R.string.state_needs_input
    SessionState.IDLE -> R.string.state_done
    SessionState.ERROR -> R.string.state_error
}

/** Seconds of frame time while [animated]; 0 (the still pose) when not. */
@Composable
private fun avatarClock(animated: Boolean): State<Double> {
    val time = remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(animated) {
        if (!animated) {
            time.doubleValue = 0.0
            return@LaunchedEffect
        }
        while (true) {
            withFrameMillis { millis -> time.doubleValue = millis / 1000.0 + 0.001 }
        }
    }
    return time
}

@Composable
private fun animationsOff(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

private const val DESIGN = 52f
private const val MOON_DESIGN = 22f
private const val MAX_MOONS = 5

// MARK: Shared drawing

private fun Double.f() = toFloat()

private fun ovalPath(x: Double, y: Double, w: Double, h: Double) = Path().apply {
    addOval(androidx.compose.ui.geometry.Rect(x.f(), y.f(), (x + w).f(), (y + h).f()))
}

private fun DrawScope.oval(color: Color, x: Double, y: Double, w: Double, h: Double) =
    drawOval(color, Offset(x.f(), y.f()), Size(w.f(), h.f()))

/** Light at the top, like the sky side of a marble. Draw inside a clip of the globe. */
private fun DrawScope.fillGlobe(r: Double, palette: PlanetPalette) {
    drawRect(
        brush = Brush.verticalGradient(listOf(palette.light, palette.base), startY = -r.f(), endY = r.f()),
        topLeft = Offset(-r.f(), -r.f()),
        size = Size((r * 2).f(), (r * 2).f()),
    )
}

/** Soft night side at the bottom right and a highlight at the top left. Draw inside a clip of the globe. */
private fun DrawScope.shadeGlobe(r: Double) {
    drawRect(
        brush = Brush.radialGradient(
            0f to Color.Black.copy(alpha = 0f),
            0.62f to Color.Black.copy(alpha = 0f),
            1f to Color.Black.copy(alpha = 0.28f),
            center = Offset((-r * 0.4).f(), (-r * 0.45).f()),
            radius = (r * 1.8).f(),
        ),
        topLeft = Offset(-r.f(), -r.f()),
        size = Size((r * 2).f(), (r * 2).f()),
    )
    oval(Color.White.copy(alpha = 0.30f), -r * 0.66, -r * 0.74, r * 0.56, r * 0.30)
}

private fun DrawScope.fillSpots(spots: List<PlanetSpot>, r: Double, turns: Double) {
    for (spot in spots) {
        val x = place(spot.u + turns * spot.rate) * r
        oval(spot.color.copy(alpha = spot.opacity.f()), x - spot.w * r / 2, (spot.y - spot.h / 2) * r, spot.w * r, spot.h * r)
    }
}

private fun roundStroke(width: Double) = Stroke(width = width.f(), cap = StrokeCap.Round, join = StrokeJoin.Round)

// MARK: Planet painter

/** Draws in a 52 × 52 design space. Port of the Mac `AvatarPainter`. [time] in seconds, 0 = still pose. */
private class PlanetPainter(
    val state: SessionState,
    val look: PlanetLook,
    val moons: List<MoonLook>,
    val time: Double,
) {
    private val tint = LoungeColors.stateTint(state)

    private val bob: Double = if (state == SessionState.RUNNING && time != 0.0) sin(time * 1.6) * 0.8 else 0.0

    /** Turns so far. While it waits for input it only rocks from side to side. */
    private val turns: Double = when {
        time == 0.0 -> 0.0
        state == SessionState.NEEDS_INPUT -> 0.035 * sin(time * 2.2)
        else -> time / look.period
    }

    fun paint(scope: DrawScope) = with(scope) {
        translate(26f, (26 + bob).f()) {
            when (state) {
                SessionState.IDLE -> drawSun()
                SessionState.NEEDS_INPUT -> drawHalo()
                else -> Unit
            }
            drawMoons(behind = true)
            drawRings(back = true)
            drawGlobe()
            drawRings(back = false)
            drawMoons(behind = false)
        }
        if (state == SessionState.NEEDS_INPUT) drawBadge()
    }

    /** Done: the sun shines from behind the planet. */
    private fun DrawScope.drawSun() {
        val r = look.radius
        val sun = Color(1.0f, 0.80f, 0.30f)
        val outer = r + 7
        val solid = ((r + 0.8) / outer).f()
        drawCircle(
            brush = Brush.radialGradient(
                0f to sun.copy(alpha = 0.95f),
                solid to sun.copy(alpha = 0.95f),
                1f to sun.copy(alpha = 0f),
                center = Offset.Zero,
                radius = outer.f(),
            ),
            radius = outer.f(),
            center = Offset.Zero,
        )
        // Rays, long and short in turn.
        val inner = r + 0.5
        val half = 0.085
        for (index in 0 until 12) {
            val angle = index * PI / 6 + 0.26
            val tip = r + if (index % 2 == 0) 6.5 else 4.2
            val ray = Path().apply {
                moveTo((cos(angle - half) * inner).f(), (sin(angle - half) * inner).f())
                lineTo((cos(angle) * tip).f(), (sin(angle) * tip).f())
                lineTo((cos(angle + half) * inner).f(), (sin(angle + half) * inner).f())
                close()
            }
            drawPath(ray, sun.copy(alpha = 0.9f))
        }
    }

    /** Needs input: thin pulsing glow in the state color, right around the planet. */
    private fun DrawScope.drawHalo() {
        val r = look.radius
        val pulse = if (time == 0.0) 1.0 else 0.5 + 0.5 * sin(time * 5)
        val strength = (0.55 + 0.45 * pulse).f()
        val outer = r + 4
        val solid = ((r + 0.6) / outer).f()
        drawCircle(
            brush = Brush.radialGradient(
                0f to tint.copy(alpha = strength),
                solid to tint.copy(alpha = strength),
                1f to tint.copy(alpha = 0f),
                center = Offset.Zero,
                radius = outer.f(),
            ),
            radius = outer.f(),
            center = Offset.Zero,
        )
    }

    private fun DrawScope.drawGlobe() {
        val r = look.radius
        val spin = turns
        clipPath(ovalPath(-r, -r, r * 2, r * 2)) {
            fillGlobe(r, look.palette)

            for (band in look.bands) {
                drawRect(
                    band.color.copy(alpha = band.opacity.f()),
                    topLeft = Offset(-r.f(), ((band.y - band.h / 2) * r).f()),
                    size = Size((r * 2).f(), (band.h * r).f()),
                )
            }

            fillSpots(look.spots, r, spin)

            val steps = 24
            for (squiggle in look.squiggles) {
                val start = place(squiggle.u + spin * squiggle.rate) * r
                val line = Path()
                for (step in 0..steps) {
                    val t = (step.toDouble() / steps - 0.5) * squiggle.length
                    val x = (start + t * r).f()
                    val y = ((squiggle.y + squiggle.amp * sin(t / squiggle.wave * PI * 2)) * r).f()
                    if (step == 0) line.moveTo(x, y) else line.lineTo(x, y)
                }
                drawPath(line, squiggle.color.copy(alpha = squiggle.opacity.f()), style = roundStroke(squiggle.width * r))
            }

            for (crack in look.cracks) {
                val start = place(crack.u + spin) * r
                val line = Path()
                crack.points.forEachIndexed { index, point ->
                    val x = (start + point.x * r).f()
                    val y = ((crack.y + point.y) * r).f()
                    if (index == 0) line.moveTo(x, y) else line.lineTo(x, y)
                }
                val glow = crack.glow
                if (glow != null) {
                    // Lava: a wide glow under a bright core, both pulse.
                    val pulse = if (time == 0.0) 0.7 else 0.5 + 0.5 * sin(time * 2.4 + crack.phase)
                    drawPath(line, glow.copy(alpha = (0.30 + 0.30 * pulse).f()), style = roundStroke(crack.width * r * 3))
                    drawPath(
                        line,
                        crack.color.copy(alpha = (0.70 + 0.30 * pulse).f()),
                        style = roundStroke(crack.width * r * (0.9 + 0.3 * pulse)),
                    )
                } else {
                    drawPath(line, crack.color.copy(alpha = crack.opacity.f()), style = roundStroke(crack.width * r))
                }
            }

            for (cap in look.caps) {
                oval(cap.color, -cap.w * r / 2, (cap.y - cap.h / 2) * r, cap.w * r, cap.h * r)
            }

            shadeGlobe(r)

            if (state == SessionState.ERROR) {
                // Eclipse: a round shadow over the right half.
                val shadow = r * 1.35
                drawCircle(
                    Color(0.05f, 0.05f, 0.12f, 0.72f),
                    radius = shadow.f(),
                    center = Offset((r * 1.05).f(), (r * 0.2).f()),
                )
            }
        }
    }

    /** [back]: the half behind the planet (drawn first). Otherwise the half in front. */
    private fun DrawScope.drawRings(back: Boolean) {
        val rings = look.rings ?: return
        val r = look.radius
        rotate(rings.tilt.f(), pivot = Offset.Zero) {
            clipRect(-40f, if (back) -40f else 0f, 40f, if (back) 0f else 40f) {
                for (part in rings.parts) {
                    val rx = part.rx * r
                    val ry = rx * rings.squash
                    val color = if (back) lerp(part.color, Color.Black, 0.18f) else part.color
                    drawOval(
                        color,
                        topLeft = Offset(-rx.f(), -ry.f()),
                        size = Size((rx * 2).f(), (ry * 2).f()),
                        style = Stroke((part.width * r).f()),
                    )
                }
            }
        }
    }

    /** One moon per running subagent. [behind]: the moons on the far side of the orbit (drawn first). */
    private fun DrawScope.drawMoons(behind: Boolean) {
        if (moons.isEmpty()) return
        rotate((look.rings?.tilt ?: -12.0).f(), pivot = Offset.Zero) {
            moons.forEachIndexed { index, moon ->
                val i = index.toDouble()
                val angle = time * (1.15 - 0.17 * i) + i * 2.4 + 0.3
                val isBehind = sin(angle) < 0
                if (isBehind != behind) return@forEachIndexed
                val rx = 23 * (1 - 0.07 * (index % 3))
                val ry = rx * 0.30
                val x = cos(angle) * rx
                val y = sin(angle) * ry
                val mr = 2.6 * if (isBehind) 0.85 else 1.0
                val center = Offset(x.f(), y.f())
                drawCircle(moon.palette.base, mr.f(), center)
                oval(moon.palette.light.copy(alpha = 0.9f), x - mr * 0.75, y - mr * 0.8, mr * 1.0, mr * 0.9)
                drawCircle(Color.Black.copy(alpha = 0.25f), mr.f(), center, style = Stroke(0.4f))
            }
        }
    }

    private fun DrawScope.drawBadge() {
        val pulse = if (time == 0.0) 1.0 else 1 + 0.08 * sin(time * 5)
        val radius = (6.5 * pulse).f()
        val center = Offset(44.5f, 8f)
        drawCircle(tint, radius, center)
        drawCircle(Color.White.copy(alpha = 0.9f), radius, center, style = Stroke(1.2f))
        // "!" drawn as a bar and a dot (no text layout in the draw phase).
        drawLine(Color.White, Offset(44.5f, 4.6f), Offset(44.5f, 8.6f), strokeWidth = 2.2f, cap = StrokeCap.Round)
        drawCircle(Color.White, radius = 1.2f, center = Offset(44.5f, 11.4f))
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF2B2B30)
@Composable
private fun AvatarPreview() {
    Column(Modifier.padding(16.dp)) {
        listOf("lounge-app", "android-shop", "vault", "billing-api", "design-tokens").forEach { name ->
            Row {
                SessionState.entries.forEach { state ->
                    Avatar(
                        state = state,
                        look = PlanetLook.make(name),
                        moons = if (state == SessionState.RUNNING) listOf("Explore", "Plan") else emptyList(),
                    )
                }
                MoonAvatar(name, animated = false)
            }
        }
    }
}
