package wtf.mahdi.agentloungecompanion.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.widget.Toast
import wtf.mahdi.agentloungecompanion.AgentLoungeApp
import wtf.mahdi.agentloungecompanion.R

/** Allow / Deny buttons of a needs-input notification. */
class DecisionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID) ?: return
        val cardId = intent.getStringExtra(EXTRA_CARD_ID) ?: return
        val allow = intent.getBooleanExtra(EXTRA_ALLOW, false)
        val container = (context.applicationContext as AgentLoungeApp).container
        if (container.connection.decide(requestId, allow)) {
            container.notifier.cancelNeedsInput(cardId)
        } else {
            Toast.makeText(context, R.string.decide_not_connected, Toast.LENGTH_LONG).show()
        }
    }

    companion object {
        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_CARD_ID = "cardId"
        const val EXTRA_ALLOW = "allow"
    }
}
