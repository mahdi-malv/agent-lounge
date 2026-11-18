package wtf.mahdi.agentloungecompanion.ui.lounge

import androidx.compose.runtime.Stable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import wtf.mahdi.agentloungecompanion.core.ConnectionState
import wtf.mahdi.agentloungecompanion.core.LoungeConnection
import wtf.mahdi.agentloungecompanion.data.PairedMac

enum class LinkStatus { CONNECTED, CONNECTING, WAITING, PAUSED }

@Stable
data class LoungeUiState(
    val macName: String = "",
    val status: LinkStatus = LinkStatus.CONNECTING,
    /** Seconds until the next try (WAITING). */
    val retryInSeconds: Int = 0,
    val failureReason: String? = null,
    val cards: List<CardUi> = emptyList(),
    val expandedIds: Set<String> = emptySet(),
    /** Card to scroll to (tapped notification). Cleared with [LoungeAction.FocusShown]. */
    val focusIndex: Int? = null,
) {
    /** Cards are from the last snapshot and may be old. */
    val isStale: Boolean get() = status != LinkStatus.CONNECTED

    companion object {
        val EMPTY = LoungeUiState()
    }
}

sealed interface LoungeAction {
    data class ToggleCard(val id: String) : LoungeAction
    data class Decide(val requestId: String, val allow: Boolean) : LoungeAction
    data class DraftChanged(val cardId: String, val text: String) : LoungeAction
    data class SendPrompt(val cardId: String) : LoungeAction
    data object Retry : LoungeAction
    data object FocusShown : LoungeAction
}

sealed interface LoungeEvent {
    data object NotConnected : LoungeEvent
    data object PromptSent : LoungeEvent
    data class PromptFailed(val reason: String) : LoungeEvent
}

class LoungeViewModel(
    private val connection: LoungeConnection,
    pairedMac: Flow<PairedMac?>,
    private val focusRequests: MutableStateFlow<String?>,
    private val clock: () -> Long = System::currentTimeMillis,
) : ViewModel() {

    private val _expandedIds = MutableStateFlow<Set<String>>(emptySet())
    private val _drafts = MutableStateFlow<Map<String, String>>(emptyMap())
    private val _sendingPrompts = MutableStateFlow<Set<String>>(emptySet())
    private val _events = MutableSharedFlow<LoungeEvent>(extraBufferCapacity = 4)
    val events: SharedFlow<LoungeEvent> = _events.asSharedFlow()

    /** Elapsed times and the retry countdown move every second. */
    private val ticks: Flow<Long> = flow {
        while (true) {
            emit(clock())
            delay(1_000)
        }
    }

    private val sortedCards = combine(
        connection.cards,
        ticks,
        connection.sentDecisions,
        _drafts,
        _sendingPrompts,
    ) { cards, now, sent, drafts, sending ->
        CardFormat.sorted(cards).map { CardFormat.toUi(it, now, sent, drafts, sending) }
    }

    init {
        viewModelScope.launch {
            connection.promptResults.collect { result ->
                _sendingPrompts.update { it - result.cardId }
                if (result.ok) {
                    _drafts.update { it - result.cardId }
                    _events.tryEmit(LoungeEvent.PromptSent)
                } else {
                    _events.tryEmit(LoungeEvent.PromptFailed(result.reason.orEmpty()))
                }
            }
        }
    }

    val uiState: StateFlow<LoungeUiState> = combine(
        connection.state,
        sortedCards,
        pairedMac,
        _expandedIds,
        focusRequests,
    ) { state, cards, mac, expanded, focusId ->
        val focusIndex = focusId?.let { id -> cards.indexOfFirst { it.id == id }.takeIf { it >= 0 } }
        LoungeUiState(
            macName = (state as? ConnectionState.Connected)?.server ?: mac?.name.orEmpty(),
            status = when (state) {
                is ConnectionState.Connected -> LinkStatus.CONNECTED
                is ConnectionState.Waiting -> LinkStatus.WAITING
                ConnectionState.Paused, ConnectionState.NotPaired -> LinkStatus.PAUSED
                is ConnectionState.Connecting -> LinkStatus.CONNECTING
            },
            retryInSeconds = (state as? ConnectionState.Waiting)
                ?.let { ((it.retryAtMillis - clock() + 999) / 1000).toInt().coerceAtLeast(0) } ?: 0,
            failureReason = (state as? ConnectionState.Waiting)?.reason,
            cards = cards,
            expandedIds = if (focusId != null) expanded + focusId else expanded,
            focusIndex = focusIndex,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), LoungeUiState.EMPTY)

    fun onAction(action: LoungeAction) {
        when (action) {
            is LoungeAction.ToggleCard -> _expandedIds.update { if (action.id in it) it - action.id else it + action.id }
            LoungeAction.Retry -> connection.retry()
            is LoungeAction.Decide -> if (!connection.decide(action.requestId, action.allow)) {
                _events.tryEmit(LoungeEvent.NotConnected)
            }
            is LoungeAction.DraftChanged -> _drafts.update { it + (action.cardId to action.text.take(MAX_PROMPT)) }
            is LoungeAction.SendPrompt -> {
                val text = _drafts.value[action.cardId]?.trim().orEmpty()
                if (text.isEmpty() || action.cardId in _sendingPrompts.value) return
                if (connection.prompt(action.cardId, text)) {
                    _sendingPrompts.update { it + action.cardId }
                } else {
                    _events.tryEmit(LoungeEvent.NotConnected)
                }
            }
            LoungeAction.FocusShown -> {
                focusRequests.value?.let { id -> _expandedIds.update { it + id } }
                focusRequests.value = null
            }
        }
    }

    private companion object {
        const val MAX_PROMPT = 4_000
    }
}
