package wtf.mahdi.agentloungecompanion.notify

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import wtf.mahdi.agentloungecompanion.AgentLoungeApp

/**
 * Keeps the Mac connection open while the app is in the background, so alerts arrive.
 * Type `connectedDevice`: a live link to the user's Mac on the local network.
 */
class LoungeService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var updates: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val container = (application as AgentLoungeApp).container
        val connection = container.connection
        val notifier = container.notifier
        val started = runCatching {
            ServiceCompat.startForeground(
                this,
                Notifier.ONGOING_ID,
                notifier.ongoing(connection.state.value, connection.cards.value),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        }
        if (started.isFailure) {
            Log.w(TAG, "Cannot start in foreground", started.exceptionOrNull())
            stopSelf()
            return START_NOT_STICKY
        }
        connection.hold(HOLDER)
        if (updates == null) {
            updates = combine(connection.state, connection.cards) { state, cards -> notifier.ongoing(state, cards) }
                .onEach(notifier::updateOngoing)
                .launchIn(scope)
        }
        return START_STICKY
    }

    override fun onDestroy() {
        (application as AgentLoungeApp).container.connection.release(HOLDER)
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "LoungeService"
        private const val HOLDER = "service"

        /** Call only while the app is in the foreground (Android 12+ start limits). */
        fun start(context: Context) {
            runCatching { ContextCompat.startForegroundService(context, Intent(context, LoungeService::class.java)) }
                .onFailure { Log.w(TAG, "Cannot start service", it) }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LoungeService::class.java))
        }
    }
}
