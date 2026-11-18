package wtf.mahdi.agentloungecompanion

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import wtf.mahdi.agentloungecompanion.ui.AppRoot
import wtf.mahdi.agentloungecompanion.ui.theme.AgentLoungeCompanionTheme

class MainActivity : ComponentActivity() {
    private val container get() = (application as AgentLoungeApp).container

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) handleIntent(intent)
        setContent {
            AgentLoungeCompanionTheme {
                AppRoot(container = container, app = application)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    /** A tapped alert notification opens its card. */
    private fun handleIntent(intent: Intent?) {
        intent?.getStringExtra(EXTRA_CARD_ID)?.let { container.focusCardId.value = it }
    }

    companion object {
        const val EXTRA_CARD_ID = "cardId"
    }
}
