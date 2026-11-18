package wtf.mahdi.agentloungecompanion.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import wtf.mahdi.agentloungecompanion.core.PairingRepository
import wtf.mahdi.agentloungecompanion.protocol.AlertKind

/** The Mac this phone paired with. */
data class PairedMac(
    val serverId: String,
    val name: String,
    val host: String,
    val port: Int,
    /** Long-term device secret (protocol v2), base64. */
    val secret: String,
    val deviceId: String,
)

data class AppSettings(
    /** Keep the connection in a foreground service, so alerts arrive with the app closed. */
    val backgroundAlerts: Boolean = true,
    val notifyNeedsInput: Boolean = true,
    val notifyDone: Boolean = true,
    val notifyError: Boolean = true,
) {
    fun notifies(kind: AlertKind): Boolean = when (kind) {
        AlertKind.NEEDS_INPUT -> notifyNeedsInput
        AlertKind.DONE -> notifyDone
        AlertKind.ERROR -> notifyError
    }

    companion object {
        val DEFAULT = AppSettings()
    }
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "lounge")

/** Pairing and settings in DataStore. The token is app-private and excluded from backups. */
class LoungeStore(context: Context) : PairingRepository {
    private val store = context.applicationContext.dataStore

    private object Keys {
        val serverId = stringPreferencesKey("mac.serverId")
        val name = stringPreferencesKey("mac.name")
        val host = stringPreferencesKey("mac.host")
        val port = intPreferencesKey("mac.port")
        /** v1 token: ignored (v2 needs a new pairing), removed on forget. */
        val legacyToken = stringPreferencesKey("mac.token")
        val secret = stringPreferencesKey("mac.secret")
        val deviceId = stringPreferencesKey("mac.deviceId")
        val background = booleanPreferencesKey("settings.backgroundAlerts")
        val notifyNeedsInput = booleanPreferencesKey("settings.notify.needsInput")
        val notifyDone = booleanPreferencesKey("settings.notify.done")
        val notifyError = booleanPreferencesKey("settings.notify.error")
    }

    override val pairedMac: Flow<PairedMac?> = store.data.map { prefs ->
        val secret = prefs[Keys.secret] ?: return@map null
        val host = prefs[Keys.host] ?: return@map null
        PairedMac(
            serverId = prefs[Keys.serverId].orEmpty(),
            name = prefs[Keys.name].orEmpty(),
            host = host,
            port = prefs[Keys.port] ?: 0,
            secret = secret,
            deviceId = prefs[Keys.deviceId].orEmpty(),
        )
    }.distinctUntilChanged()

    val settings: Flow<AppSettings> = store.data.map { prefs ->
        AppSettings(
            backgroundAlerts = prefs[Keys.background] ?: AppSettings.DEFAULT.backgroundAlerts,
            notifyNeedsInput = prefs[Keys.notifyNeedsInput] ?: AppSettings.DEFAULT.notifyNeedsInput,
            notifyDone = prefs[Keys.notifyDone] ?: AppSettings.DEFAULT.notifyDone,
            notifyError = prefs[Keys.notifyError] ?: AppSettings.DEFAULT.notifyError,
        )
    }.distinctUntilChanged()

    override suspend fun savePairing(mac: PairedMac) {
        store.edit { prefs ->
            prefs[Keys.serverId] = mac.serverId
            prefs[Keys.name] = mac.name
            prefs[Keys.host] = mac.host
            prefs[Keys.port] = mac.port
            prefs[Keys.secret] = mac.secret
            prefs.remove(Keys.legacyToken)
            prefs[Keys.deviceId] = mac.deviceId
        }
    }

    /** New address for the paired Mac (DHCP change), found by discovery. */
    override suspend fun updateAddress(serverId: String, host: String, port: Int) {
        store.edit { prefs ->
            if (prefs[Keys.serverId] == serverId) {
                prefs[Keys.host] = host
                prefs[Keys.port] = port
            }
        }
    }

    override suspend fun updateName(name: String) {
        store.edit { prefs -> if (name.isNotEmpty()) prefs[Keys.name] = name }
    }

    override suspend fun forgetMac() {
        store.edit { prefs ->
            listOf(Keys.serverId, Keys.name, Keys.host, Keys.secret, Keys.legacyToken, Keys.deviceId).forEach { prefs.remove(it) }
            prefs.remove(Keys.port)
        }
    }

    suspend fun setBackgroundAlerts(enabled: Boolean) {
        store.edit { it[Keys.background] = enabled }
    }

    suspend fun setNotify(kind: AlertKind, enabled: Boolean) {
        val key = when (kind) {
            AlertKind.NEEDS_INPUT -> Keys.notifyNeedsInput
            AlertKind.DONE -> Keys.notifyDone
            AlertKind.ERROR -> Keys.notifyError
        }
        store.edit { it[key] = enabled }
    }
}
