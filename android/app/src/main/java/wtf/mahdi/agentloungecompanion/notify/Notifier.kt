package wtf.mahdi.agentloungecompanion.notify

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import wtf.mahdi.agentloungecompanion.MainActivity
import wtf.mahdi.agentloungecompanion.R
import wtf.mahdi.agentloungecompanion.core.ConnectionState
import wtf.mahdi.agentloungecompanion.protocol.AlertKind
import wtf.mahdi.agentloungecompanion.protocol.RemoteAlert
import wtf.mahdi.agentloungecompanion.protocol.RemoteCard
import wtf.mahdi.agentloungecompanion.protocol.SessionState

/** Notification channels, alert notifications, and the ongoing service notification. */
class Notifier(context: Context) {
    private val context = context.applicationContext
    private val manager = NotificationManagerCompat.from(this.context)

    fun createChannels() {
        fun channel(id: String, name: Int, importance: Int) =
            NotificationChannelCompat.Builder(id, importance).setName(text(name))
        val channels = listOf(
            channel(CHANNEL_NEEDS_INPUT, R.string.channel_needs_input, NotificationManagerCompat.IMPORTANCE_HIGH).build(),
            channel(CHANNEL_DONE, R.string.channel_done, NotificationManagerCompat.IMPORTANCE_DEFAULT).build(),
            channel(CHANNEL_ERROR, R.string.channel_error, NotificationManagerCompat.IMPORTANCE_HIGH).build(),
            channel(CHANNEL_CONNECTION, R.string.channel_connection, NotificationManagerCompat.IMPORTANCE_MIN).setShowBadge(false).build(),
        )
        manager.createNotificationChannelsCompat(channels)
    }

    val canPost: Boolean
        get() = manager.areNotificationsEnabled() &&
            (android.os.Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    /** One notification per card and kind; a newer alert of the same kind replaces it. */
    fun postAlert(alert: RemoteAlert) {
        if (!canPost) return
        val (channel, label) = when (alert.kind) {
            AlertKind.NEEDS_INPUT -> CHANNEL_NEEDS_INPUT to R.string.state_needs_input
            AlertKind.DONE -> CHANNEL_DONE to R.string.state_done
            AlertKind.ERROR -> CHANNEL_ERROR to R.string.state_error
        }
        val builder = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_lounge)
            .setContentTitle(alert.title.ifEmpty { text(label) })
            .setContentText(alert.message)
            .setSubText(text(label))
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.message))
            .setCategory(if (alert.kind == AlertKind.DONE) NotificationCompat.CATEGORY_STATUS else NotificationCompat.CATEGORY_REMINDER)
            .setGroup(GROUP_ALERTS)
            .setAutoCancel(true)
            .setContentIntent(openApp(alert.cardId))
        alert.approval?.let { approval ->
            approval.detail?.let { builder.setStyle(NotificationCompat.BigTextStyle().bigText("${alert.message}\n\n$it")) }
            builder.addAction(decisionAction(alert.cardId, approval.id, allow = false))
            builder.addAction(decisionAction(alert.cardId, approval.id, allow = true))
        }
        @Suppress("MissingPermission") // Checked in canPost.
        manager.notify(alert.cardId, alert.kind.ordinal, builder.build())
    }

    fun cancelNeedsInput(cardId: String) {
        manager.cancel(cardId, AlertKind.NEEDS_INPUT.ordinal)
    }

    /** Needs the phone unlocked: an answer can run a command on the Mac. */
    private fun decisionAction(cardId: String, requestId: String, allow: Boolean): NotificationCompat.Action {
        val intent = Intent(context, DecisionReceiver::class.java)
            .putExtra(DecisionReceiver.EXTRA_REQUEST_ID, requestId)
            .putExtra(DecisionReceiver.EXTRA_CARD_ID, cardId)
            .putExtra(DecisionReceiver.EXTRA_ALLOW, allow)
        val pending = PendingIntent.getBroadcast(
            context,
            "$requestId:$allow".hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val label = text(if (allow) R.string.action_allow_once else R.string.action_deny)
        return NotificationCompat.Action.Builder(null, label, pending)
            .setAuthenticationRequired(true)
            .build()
    }

    /** Removes alert notifications of cards that need no attention any more. */
    fun clearResolved(cards: List<RemoteCard>) {
        val byId = cards.associateBy { it.id }
        manager.activeNotifications
            .filter { it.tag != null && it.id in AlertKind.entries.indices }
            .forEach { active ->
                val card = byId[active.tag]
                val stale = when (AlertKind.entries[active.id]) {
                    AlertKind.NEEDS_INPUT -> card?.state != SessionState.NEEDS_INPUT
                    AlertKind.ERROR -> card?.state != SessionState.ERROR
                    AlertKind.DONE -> card == null || card.state == SessionState.RUNNING
                }
                if (stale) manager.cancel(active.tag, active.id)
            }
    }

    fun ongoing(state: ConnectionState, cards: List<RemoteCard>): Notification {
        val title = when (state) {
            is ConnectionState.Connected -> context.getString(R.string.ongoing_connected, state.server)
            is ConnectionState.Connecting, is ConnectionState.Waiting -> text(R.string.ongoing_connecting)
            ConnectionState.Paused, ConnectionState.NotPaired -> text(R.string.ongoing_paused)
        }
        val running = cards.count { it.state == SessionState.RUNNING }
        val waiting = cards.count { it.state == SessionState.NEEDS_INPUT }
        val body = if (cards.isEmpty()) {
            text(R.string.ongoing_no_agents)
        } else {
            context.resources.getQuantityString(R.plurals.ongoing_agents, cards.size, cards.size, running, waiting)
        }
        return NotificationCompat.Builder(context, CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_lounge)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Own group: some launchers (One UI) otherwise stack it over the alerts.
            .setGroup(GROUP_CONNECTION)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(openApp(null))
            .build()
    }

    fun updateOngoing(notification: Notification) {
        if (canPost) {
            @Suppress("MissingPermission")
            manager.notify(ONGOING_ID, notification)
        }
    }

    private fun openApp(cardId: String?): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply { if (cardId != null) putExtra(MainActivity.EXTRA_CARD_ID, cardId) }
        return PendingIntent.getActivity(
            context,
            cardId?.hashCode() ?: 0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun text(id: Int) = context.getString(id)

    companion object {
        const val ONGOING_ID = 1
        private const val CHANNEL_NEEDS_INPUT = "alert.needsInput"
        private const val CHANNEL_DONE = "alert.done"
        private const val CHANNEL_ERROR = "alert.error"
        private const val CHANNEL_CONNECTION = "connection"
        private const val GROUP_ALERTS = "alerts"
        private const val GROUP_CONNECTION = "connection"
    }
}
