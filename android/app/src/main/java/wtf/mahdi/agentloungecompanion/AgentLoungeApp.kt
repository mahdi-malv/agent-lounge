package wtf.mahdi.agentloungecompanion

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import wtf.mahdi.agentloungecompanion.core.LoungeConnection
import wtf.mahdi.agentloungecompanion.data.AppSettings
import wtf.mahdi.agentloungecompanion.data.LoungeStore
import wtf.mahdi.agentloungecompanion.net.LoungeSockets
import wtf.mahdi.agentloungecompanion.net.MacDiscovery
import wtf.mahdi.agentloungecompanion.notify.LoungeService
import wtf.mahdi.agentloungecompanion.notify.Notifier

class AgentLoungeApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        container.start()
    }
}

/** App-wide objects. Manual wiring: the app is small. */
class AppContainer(private val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val store = LoungeStore(app)
    val discovery = MacDiscovery(app)
    val notifier = Notifier(app)
    val connection = LoungeConnection(store, discovery, LoungeSockets(), scope)
    val settings: StateFlow<AppSettings> = store.settings.stateIn(scope, SharingStarted.Eagerly, AppSettings.DEFAULT)

    /** Card to show, from a tapped alert notification. Consumed by the lounge screen. */
    val focusCardId = MutableStateFlow<String?>(null)

    private val inForeground = MutableStateFlow(false)
    private val wantsService = MutableStateFlow(false)

    fun start() {
        notifier.createChannels()
        connection.start()

        scope.launch {
            connection.alerts.collect { alert ->
                if (settings.value.notifies(alert.kind)) notifier.postAlert(alert)
            }
        }
        scope.launch { connection.cards.collect(notifier::clearResolved) }

        // Background alerts: service runs while paired and the setting is on.
        scope.launch {
            combine(store.pairedMac, settings) { mac, s -> mac != null && s.backgroundAlerts }
                .distinctUntilChanged()
                .collect { want ->
                    wantsService.value = want
                    if (!want) LoungeService.stop(app) else if (inForeground.value) LoungeService.start(app)
                }
        }

        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                inForeground.value = true
                connection.hold(UI_HOLDER)
                // A foreground service can only be started from the foreground. Read the store
                // directly: right after launch `wantsService` may not be loaded yet.
                scope.launch {
                    val want = store.pairedMac.first() != null && store.settings.first().backgroundAlerts
                    if (want) LoungeService.start(app)
                }
            }

            override fun onStop(owner: LifecycleOwner) {
                inForeground.value = false
                connection.release(UI_HOLDER)
            }
        })
    }

    private companion object {
        const val UI_HOLDER = "ui"
    }
}

object Permissions {
    /** Android 17 (API 37) local network protection. Not a runtime permission before that. */
    const val LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    private const val LOCAL_NETWORK_SDK = 37

    val needsLocalNetwork: Boolean get() = Build.VERSION.SDK_INT >= LOCAL_NETWORK_SDK

    fun hasLocalNetwork(context: Context): Boolean =
        !needsLocalNetwork || granted(context, LOCAL_NETWORK)

    fun hasNotifications(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || granted(context, Manifest.permission.POST_NOTIFICATIONS)

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
