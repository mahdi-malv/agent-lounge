package wtf.mahdi.agentloungecompanion.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sin

// Port of the Mac app's `Planet.swift`. Keep the random draws in the same order as there: the Mac
// sends a seed and an identity, and the phone must make the same planet from them.

/** Deterministic random numbers from a name (FNV-1a seed, SplitMix64 steps). Same values as the Mac. */
class SeededRandom(seed: String) {
    private var state: Long

    init {
        var hash = 0xcbf29ce484222325uL.toLong()
        for (byte in seed.encodeToByteArray()) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 0x100000001b3L // Long overflow = the Mac's wrapping multiply
        }
        state = hash
    }

    /** 0 until 1 */
    fun next(): Double {
        state += 0x9E3779B97F4A7C15uL.toLong()
        var z = state
        z = (z xor (z ushr 30)) * 0xBF58476D1CE4E5B9uL.toLong()
        z = (z xor (z ushr 27)) * 0x94D049BB133111EBuL.toLong()
        z = z xor (z ushr 31)
        return (z ushr 11).toDouble() / 9_007_199_254_740_992.0
    }

    fun range(low: Double, high: Double): Double = low + (high - low) * next()

    /** 0 until [count] */
    fun index(count: Int): Int = min(count - 1, (next() * count).toInt())
}

/** Soft colors of one planet: light top, base, dark markings, pale clouds. */
data class PlanetPalette(val light: Color, val base: Color, val dark: Color, val pale: Color) {
    companion object {
        private fun make(light: FloatArray, base: FloatArray, dark: FloatArray, pale: FloatArray) =
            PlanetPalette(rgb(light), rgb(base), rgb(dark), rgb(pale))

        private fun rgb(v: FloatArray) = Color(v[0], v[1], v[2])
        private fun c(r: Float, g: Float, b: Float) = floatArrayOf(r, g, b)

        val all: List<PlanetPalette> = listOf(
            make(c(1.00f, 0.90f, 0.82f), c(0.88f, 0.72f, 0.62f), c(0.60f, 0.40f, 0.36f), c(1.00f, 0.97f, 0.92f)), // sand
            make(c(1.00f, 0.88f, 0.88f), c(0.90f, 0.66f, 0.68f), c(0.64f, 0.38f, 0.44f), c(1.00f, 0.95f, 0.94f)), // rose
            make(c(0.90f, 0.96f, 0.86f), c(0.68f, 0.80f, 0.66f), c(0.40f, 0.54f, 0.44f), c(0.97f, 1.00f, 0.94f)), // sage
            make(c(0.86f, 0.93f, 1.00f), c(0.62f, 0.76f, 0.92f), c(0.36f, 0.48f, 0.70f), c(0.95f, 0.98f, 1.00f)), // powder blue
            make(c(0.93f, 0.89f, 1.00f), c(0.74f, 0.68f, 0.92f), c(0.48f, 0.40f, 0.68f), c(0.98f, 0.96f, 1.00f)), // lavender
            make(c(1.00f, 0.90f, 0.78f), c(0.95f, 0.70f, 0.52f), c(0.72f, 0.42f, 0.30f), c(1.00f, 0.96f, 0.88f)), // peach
            make(c(1.00f, 0.95f, 0.76f), c(0.94f, 0.80f, 0.50f), c(0.70f, 0.54f, 0.28f), c(1.00f, 0.98f, 0.90f)), // butter
            make(c(0.86f, 0.98f, 0.95f), c(0.60f, 0.84f, 0.80f), c(0.32f, 0.56f, 0.56f), c(0.95f, 1.00f, 0.98f)), // seafoam
            make(c(0.96f, 0.86f, 0.94f), c(0.80f, 0.60f, 0.76f), c(0.54f, 0.34f, 0.52f), c(1.00f, 0.95f, 0.99f)), // mauve
            make(c(0.92f, 0.92f, 0.95f), c(0.72f, 0.72f, 0.80f), c(0.46f, 0.46f, 0.56f), c(0.98f, 0.98f, 1.00f)), // stone
            make(c(1.00f, 0.86f, 0.80f), c(0.94f, 0.60f, 0.54f), c(0.68f, 0.34f, 0.34f), c(1.00f, 0.94f, 0.90f)), // coral
            make(c(0.88f, 0.94f, 1.00f), c(0.66f, 0.74f, 0.96f), c(0.40f, 0.44f, 0.76f), c(0.96f, 0.98f, 1.00f)), // periwinkle
            make(c(0.96f, 0.88f, 0.80f), c(0.78f, 0.62f, 0.52f), c(0.50f, 0.36f, 0.30f), c(1.00f, 0.95f, 0.88f)), // cocoa
            make(c(0.94f, 0.98f, 0.80f), c(0.80f, 0.88f, 0.56f), c(0.52f, 0.62f, 0.32f), c(0.99f, 1.00f, 0.90f)), // lime
            make(c(0.84f, 0.96f, 1.00f), c(0.56f, 0.82f, 0.94f), c(0.30f, 0.54f, 0.70f), c(0.94f, 0.99f, 1.00f)), // sky
            make(c(1.00f, 0.88f, 0.94f), c(0.94f, 0.64f, 0.78f), c(0.70f, 0.36f, 0.54f), c(1.00f, 0.95f, 0.98f)), // blush
        )
    }
}

// Sizes below are in planet radii. `u` is a longitude, 0 until 1 (0.5 = facing us).

/** Straight cloud belt. */
data class PlanetBand(val y: Double, val h: Double, val color: Color, val opacity: Double)

/** Oval that moves with the rotation. [rate] = speed relative to the surface (clouds move faster). */
data class PlanetSpot(
    val u: Double, val y: Double, val w: Double, val h: Double,
    val color: Color, val opacity: Double, val rate: Double = 1.0,
)

/** Wavy cloud line that moves with the rotation. */
data class PlanetSquiggle(
    val u: Double, val y: Double, val length: Double, val amp: Double, val wave: Double, val width: Double,
    val color: Color, val opacity: Double, val rate: Double = 1.0,
)

data class PlanetPoint(val x: Double, val y: Double)

/** Jagged line: ice crack, canyon, lava stream. [glow] set = lava that pulses. */
data class PlanetCrack(
    val u: Double, val y: Double, val points: List<PlanetPoint>, val width: Double,
    val color: Color, val opacity: Double, val glow: Color?, val phase: Double,
)

data class PlanetCap(val y: Double, val w: Double, val h: Double, val color: Color)

data class PlanetRingPart(val rx: Double, val width: Double, val color: Color)

/** [tilt] in degrees. [squash] = height / width of the ring ellipse. */
data class PlanetRings(val tilt: Double, val squash: Double, val parts: List<PlanetRingPart>)

private fun rgb(r: Float, g: Float, b: Float) = Color(r, g, b)

/** Random jagged line around (u, y). [heading] in radians, [step] = length of one piece. */
private fun makeCrack(
    random: SeededRandom, u: Double, y: Double, segments: Int, step: Double, heading: Double,
    width: Double, color: Color, opacity: Double, glow: Color?,
): PlanetCrack {
    val points = mutableListOf(PlanetPoint(0.0, 0.0))
    var angle = heading
    var offsetX = 0.0
    var offsetY = 0.0
    repeat(segments) {
        angle += random.range(-0.75, 0.75)
        offsetX += cos(angle) * step
        offsetY += sin(angle) * step
        points += PlanetPoint(offsetX, offsetY)
    }
    // Center the line on its anchor, so it is out of sight when the anchor wraps around the planet.
    val midX = (points.minOf { it.x } + points.maxOf { it.x }) / 2
    val midY = (points.minOf { it.y } + points.maxOf { it.y }) / 2
    val centered = points.map { PlanetPoint(it.x - midX, it.y - midY) }
    val phase = random.range(0.0, 6.28)
    return PlanetCrack(u, y, centered, width, color, opacity, glow, phase)
}

/**
 * How one card's planet looks. Identities 0 until 16 are made from a name (soft colors, belts or
 * wavy clouds or dark land, caps, rings). Identities 16 to 20 are the fixed worlds: blue planet,
 * red planet, grey moon, lava world, ice world.
 */
data class PlanetLook(
    val identity: Int,
    val palette: PlanetPalette,
    /** Design points (52 × 52 space). */
    val radius: Double,
    /** Seconds per turn. */
    val period: Double,
    val bands: List<PlanetBand> = emptyList(),
    val spots: List<PlanetSpot> = emptyList(),
    val squiggles: List<PlanetSquiggle> = emptyList(),
    val cracks: List<PlanetCrack> = emptyList(),
    val caps: List<PlanetCap> = emptyList(),
    val rings: PlanetRings? = null,
) {
    companion object {
        val identityCount = PlanetPalette.all.size + 5

        /** [identity]: use this one, not the one the name picks (the Mac sends it). */
        fun make(seed: String, identity: Int? = null): PlanetLook {
            val paletteCount = PlanetPalette.all.size
            // The prefixes only shuffle which name gets which planet.
            val random = SeededRandom("orbit-69/$seed")
            val ownColors = random.index(paletteCount)
            val kindRandom = SeededRandom("kind/$seed")
            val kindRoll = kindRandom.next()
            val kindPick = kindRandom.index(5)
            val ownIdentity = if (kindRoll < 0.4) paletteCount + kindPick else ownColors
            val chosen = (identity ?: ownIdentity).coerceIn(0, identityCount - 1)
            if (chosen >= paletteCount) return fixedWorld(chosen - paletteCount)

            val palette = PlanetPalette.all[chosen]
            // 0 = cloud belts, 1 = wavy clouds, 2 = dark land with clouds.
            val style = random.index(3)
            val ringRoll = random.next()
            val capRoll = random.next()
            val sizeRoll = random.next()
            val hasRings = ringRoll < 0.3
            val radius = if (hasRings) 13.5 else 15.5 + sizeRoll * 3
            val period = random.range(10.0, 18.0)

            val bands = mutableListOf<PlanetBand>()
            val spots = mutableListOf<PlanetSpot>()
            val squiggles = mutableListOf<PlanetSquiggle>()
            val caps = mutableListOf<PlanetCap>()

            when (style) {
                0 -> {
                    val count = 3 + random.index(3)
                    for (index in 0 until count) {
                        val shift = random.range(-0.2, 0.2)
                        val y = -0.8 + (index + 0.5 + shift) * 1.6 / count
                        val h = random.range(0.12, 0.26)
                        val opacity = random.range(0.45, 0.75)
                        val color = if (index % 2 == 0) palette.dark else palette.pale
                        bands += PlanetBand(y, h, color, opacity)
                    }
                    for (index in 0 until 3) {
                        val u = (index + random.next()) / 3
                        val y = random.range(-0.7, 0.7)
                        val w = random.range(0.3, 0.6)
                        spots += PlanetSpot(u, y, w, 0.08, palette.pale, 0.85)
                    }
                }
                1 -> {
                    val upper = random.range(-0.6, -0.3)
                    val lower = random.range(0.3, 0.6)
                    bands += PlanetBand(upper, 0.2, palette.dark, 0.22)
                    bands += PlanetBand(lower, 0.24, palette.dark, 0.22)
                    for (index in 0 until 6) {
                        val position = index * 0.37 + random.range(0.0, 0.1)
                        val u = position - floor(position)
                        val y = -0.72 + index * 0.29 + random.range(-0.06, 0.06)
                        val length = random.range(0.9, 1.5)
                        val amp = random.range(0.05, 0.09)
                        val wave = random.range(0.38, 0.58)
                        val width = random.range(0.09, 0.12)
                        val color = if (index % 2 == 0) palette.pale else palette.dark
                        squiggles += PlanetSquiggle(u, y, length, amp, wave, width, color, 0.8)
                    }
                }
                else -> {
                    for (index in 0 until 5) {
                        val u = (index + random.next()) / 5
                        val y = random.range(-0.55, 0.55)
                        val w = random.range(0.4, 0.9)
                        val h = random.range(0.22, 0.42)
                        spots += PlanetSpot(u, y, w, h, palette.dark, 0.6)
                    }
                    for (index in 0 until 3) {
                        val u = (index + random.next()) / 3
                        val y = random.range(-0.6, 0.6)
                        val length = random.range(0.7, 1.1)
                        squiggles += PlanetSquiggle(u, y, length, 0.05, 0.42, 0.09, palette.pale, 0.9, rate = 1.35)
                    }
                }
            }

            if (style != 0 && capRoll < 0.6) {
                val top = random.range(0.85, 1.1)
                caps += PlanetCap(-1.0, top, 0.30, palette.pale)
                if (capRoll < 0.3) {
                    val bottom = random.range(0.6, 0.9)
                    caps += PlanetCap(1.0, bottom, 0.24, palette.pale)
                }
            }

            val rings = if (hasRings) {
                val tilt = random.range(-24.0, 16.0)
                val squash = random.range(0.26, 0.34)
                PlanetRings(
                    tilt, squash,
                    listOf(
                        PlanetRingPart(1.36, 0.20, lerp(palette.dark, palette.base, 0.4f)),
                        PlanetRingPart(1.64, 0.20, lerp(palette.pale, palette.base, 0.3f)),
                    ),
                )
            } else null

            return PlanetLook(chosen, palette, radius, period, bands, spots, squiggles, emptyList(), caps, rings)
        }

        /** 0 = blue planet, 1 = red planet, 2 = grey moon, 3 = lava world, anything else = ice world. */
        private fun fixedWorld(kind: Int): PlanetLook {
            val first = PlanetPalette.all.size
            val white = Color.White
            when (kind) {
                0 -> {
                    val land = rgb(0.44f, 0.78f, 0.48f)
                    val land2 = rgb(0.62f, 0.82f, 0.46f)
                    val palette = PlanetPalette(rgb(0.62f, 0.83f, 1.0f), rgb(0.32f, 0.60f, 0.95f), land, white)
                    val spots = listOf(
                        PlanetSpot(0.42, -0.36, 0.66, 0.52, land, 1.0),
                        PlanetSpot(0.465, 0.04, 0.30, 0.40, land, 1.0),
                        PlanetSpot(0.50, 0.44, 0.38, 0.52, land2, 1.0),
                        PlanetSpot(0.82, -0.38, 0.92, 0.48, land, 1.0),
                        PlanetSpot(0.78, 0.20, 0.46, 0.60, land2, 1.0),
                        PlanetSpot(0.95, 0.56, 0.30, 0.22, land, 1.0),
                        PlanetSpot(0.12, 0.08, 0.26, 0.18, land, 1.0),
                    )
                    val clouds = listOf(
                        Triple(0.30, -0.08, 0.70), Triple(0.66, 0.36, 0.60),
                        Triple(0.02, 0.58, 0.56), Triple(0.93, -0.58, 0.52),
                    ).map { (u, y, length) -> PlanetSquiggle(u, y, length, 0.04, 0.40, 0.10, white, 0.92, rate = 1.35) }
                    val caps = listOf(PlanetCap(-1.0, 1.1, 0.30, white), PlanetCap(1.0, 0.9, 0.24, white))
                    return PlanetLook(first, palette, 18.0, 14.0, spots = spots, squiggles = clouds, caps = caps)
                }
                1 -> {
                    val dark = rgb(0.66f, 0.28f, 0.22f)
                    val crater = rgb(0.56f, 0.22f, 0.18f)
                    val cap = rgb(1.0f, 0.96f, 0.92f)
                    val palette = PlanetPalette(rgb(1.0f, 0.70f, 0.52f), rgb(0.90f, 0.46f, 0.32f), dark, cap)
                    val random = SeededRandom("mars")
                    val spots = mutableListOf(
                        PlanetSpot(0.45, -0.12, 0.80, 0.32, dark, 0.6),
                        PlanetSpot(0.55, 0.34, 0.46, 0.28, dark, 0.6),
                        PlanetSpot(0.90, 0.02, 0.66, 0.38, dark, 0.6),
                        PlanetSpot(0.15, -0.40, 0.46, 0.22, dark, 0.6),
                        PlanetSpot(0.20, 0.45, 0.40, 0.20, dark, 0.6),
                    )
                    for (index in 0 until 6) {
                        val size = random.range(0.10, 0.20)
                        val u = (index + random.next()) / 6
                        val y = random.range(-0.65, 0.65)
                        spots += PlanetSpot(u, y, size, size, crater, 0.7)
                    }
                    val cracks = listOf(
                        makeCrack(random, 0.70, 0.30, 5, 0.20, 0.1, 0.07, rgb(0.50f, 0.18f, 0.15f), 0.8, null),
                    )
                    val caps = listOf(PlanetCap(-1.0, 0.9, 0.30, cap), PlanetCap(1.0, 0.55, 0.18, cap))
                    return PlanetLook(first + 1, palette, 17.0, 14.0, spots = spots, cracks = cracks, caps = caps)
                }
                2 -> {
                    val dark = rgb(0.50f, 0.50f, 0.56f)
                    val floor = rgb(0.82f, 0.82f, 0.86f)
                    val palette = PlanetPalette(rgb(0.93f, 0.93f, 0.95f), rgb(0.72f, 0.72f, 0.76f), dark, rgb(0.97f, 0.97f, 0.99f))
                    val random = SeededRandom("moon")
                    val spots = mutableListOf<PlanetSpot>()
                    for (index in 0 until 3) {
                        val u = (index + random.next()) / 3
                        val y = random.range(-0.4, 0.4)
                        val w = random.range(0.6, 0.9)
                        val h = random.range(0.4, 0.6)
                        spots += PlanetSpot(u, y, w, h, dark, 0.30)
                    }
                    for (index in 0 until 9) {
                        val u = (index + random.next()) / 9
                        val y = random.range(-0.7, 0.7)
                        val size = random.range(0.14, 0.34)
                        spots += PlanetSpot(u, y, size, size, dark, 0.75)
                        spots += PlanetSpot(u + 0.008, y + 0.035, size * 0.72, size * 0.72, floor, 0.55)
                    }
                    return PlanetLook(first + 2, palette, 16.0, 16.0, spots = spots)
                }
                3 -> {
                    val dark = rgb(0.13f, 0.11f, 0.15f)
                    val core = rgb(1.0f, 0.82f, 0.32f)
                    val glow = rgb(1.0f, 0.40f, 0.10f)
                    val palette = PlanetPalette(rgb(0.52f, 0.44f, 0.46f), rgb(0.28f, 0.23f, 0.27f), dark, core)
                    val random = SeededRandom("lava")
                    val spots = mutableListOf<PlanetSpot>()
                    for (index in 0 until 5) {
                        val u = (index + random.next()) / 5
                        val y = random.range(-0.55, 0.55)
                        val w = random.range(0.4, 0.8)
                        val h = random.range(0.25, 0.45)
                        spots += PlanetSpot(u, y, w, h, dark, 0.55)
                    }
                    val cracks = mutableListOf<PlanetCrack>()
                    for (index in 0 until 9) {
                        val u = (index + random.next()) / 9
                        val y = random.range(-0.62, 0.62)
                        val heading = random.range(0.0, 6.28)
                        cracks += makeCrack(random, u, y, 4, 0.21, heading, 0.07, core, 1.0, glow)
                    }
                    for (index in 0 until 4) {
                        val size = random.range(0.12, 0.18)
                        val u = (index + random.next()) / 4
                        val y = random.range(-0.6, 0.6)
                        spots += PlanetSpot(u, y, size, size, glow, 0.95)
                    }
                    return PlanetLook(first + 3, palette, 16.5, 15.0, spots = spots, cracks = cracks)
                }
                else -> {
                    val line = rgb(0.34f, 0.56f, 0.74f)
                    val palette = PlanetPalette(rgb(0.97f, 0.99f, 1.0f), rgb(0.74f, 0.89f, 0.97f), line, white)
                    val random = SeededRandom("ice")
                    val spots = mutableListOf<PlanetSpot>()
                    for (index in 0 until 4) {
                        val u = (index + random.next()) / 4
                        val y = random.range(-0.6, 0.6)
                        val w = random.range(0.5, 0.9)
                        val h = random.range(0.2, 0.4)
                        spots += PlanetSpot(u, y, w, h, white, 0.55)
                    }
                    val cracks = mutableListOf<PlanetCrack>()
                    for (index in 0 until 10) {
                        val u = (index + random.next()) / 10
                        val y = random.range(-0.65, 0.65)
                        val heading = random.range(0.0, 3.14)
                        val width = random.range(0.035, 0.065)
                        cracks += makeCrack(random, u, y, 5, 0.22, heading, width, line, 0.85, null)
                    }
                    return PlanetLook(first + 4, palette, 17.0, 17.0, spots = spots, cracks = cracks)
                }
            }
        }
    }
}

/** A subagent's moon. Made from its name, so the moon in orbit and the moon in its row match. */
data class MoonLook(val palette: PlanetPalette, val craters: List<PlanetSpot>) {
    companion object {
        fun make(name: String): MoonLook {
            val random = SeededRandom(name)
            val palette = PlanetPalette.all[random.index(PlanetPalette.all.size)]
            val marks = SeededRandom("$name#moon")
            val craters = (0 until 5).map { index ->
                val u = (index + marks.next()) / 5
                val y = marks.range(-0.6, 0.6)
                val size = marks.range(0.28, 0.5)
                PlanetSpot(u, y, size, size, palette.dark, 0.55)
            }
            return MoonLook(palette, craters)
        }
    }
}

/** Horizontal place of longitude [u], in radii. -1 to 1 is the side that faces us. */
internal fun place(u: Double): Double = (u - floor(u)) * 4 - 2
