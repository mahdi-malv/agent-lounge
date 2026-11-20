package wtf.mahdi.agentloungecompanion.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Mac sends a seed and an identity; the phone must make the same planet. Expected values come
 * from the Mac's `SeededRandom` and `PlanetLook.make` (Swift), run on the same names.
 */
class PlanetTest {
    @Test
    fun randomMatchesMac() {
        val random = SeededRandom("hello")
        assertEquals(0.9527730210495764, random.next(), 0.0)
        assertEquals(0.6188446070958747, random.next(), 0.0)
        assertEquals(0.1711682940686554, random.next(), 0.0)
    }

    @Test
    fun randomHashesUtf8LikeMac() {
        assertEquals(0.11027744193129085, SeededRandom("plänet").next(), 0.0)
    }

    @Test
    fun identityMatchesMac() {
        val expected = mapOf(
            "lounge-app" to 16, "android-shop" to 16, "vault" to 4, "billing-api" to 18,
            "design-tokens" to 2, "website" to 8, "api" to 17, "site" to 19,
        )
        for ((seed, identity) in expected) {
            assertEquals(seed, identity, PlanetLook.make(seed).identity)
        }
    }

    @Test
    fun generatedPlanetMatchesMac() {
        // vault: dark land (style 2): 5 patches + 3 clouds.
        val vault = PlanetLook.make("vault")
        assertEquals(17.553932354059217, vault.radius, 1e-12)
        assertEquals(14.59654134523355, vault.period, 1e-12)
        assertEquals(5, vault.spots.size)
        assertEquals(3, vault.squiggles.size)
        assertNull(vault.rings)

        // design-tokens: cloud belts (style 0).
        val tokens = PlanetLook.make("design-tokens")
        assertEquals(17.40327943926751, tokens.radius, 1e-12)
        assertEquals(13.724403930451622, tokens.period, 1e-12)
        assertTrue(tokens.bands.size in 3..5)
        assertTrue(tokens.squiggles.isEmpty())

        // website: wavy clouds (style 1).
        val website = PlanetLook.make("website")
        assertEquals(16.356962898602095, website.radius, 1e-12)
        assertEquals(16.741363464798514, website.period, 1e-12)
        assertEquals(6, website.squiggles.size)
    }

    @Test
    fun givenIdentityWinsOverName() {
        assertEquals(3, PlanetLook.make("lounge-app", identity = 3).identity)
        assertEquals(20, PlanetLook.make("vault", identity = 20).identity)
    }

    @Test
    fun badIdentityFromMacIsClamped() {
        assertEquals(PlanetLook.identityCount - 1, PlanetLook.make("x", identity = 99).identity)
        assertEquals(0, PlanetLook.make("x", identity = -1).identity)
    }

    @Test
    fun everyIdentityMakesAPlanet() {
        for (identity in 0 until PlanetLook.identityCount) {
            val look = PlanetLook.make("seed", identity)
            assertEquals(identity, look.identity)
            assertTrue(look.radius in 13.0..19.0)
        }
    }

    @Test
    fun sameNameSameMoon() {
        assertEquals(MoonLook.make("Explore"), MoonLook.make("Explore"))
        assertEquals(5, MoonLook.make("Plan").craters.size)
    }

    @Test
    fun placeWrapsLongitude() {
        assertEquals(0.0, place(0.5), 1e-12)
        assertEquals(0.0, place(1.5), 1e-12)
        assertEquals(0.0, place(-0.5), 1e-12)
        assertEquals(-2.0, place(0.0), 1e-12)
    }
}
