package wtf.mahdi.agentloungecompanion.ui.pair

import androidx.compose.runtime.Stable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import wtf.mahdi.agentloungecompanion.core.LoungeConnection
import wtf.mahdi.agentloungecompanion.core.PairOutcome
import wtf.mahdi.agentloungecompanion.net.DiscoveredMac
import wtf.mahdi.agentloungecompanion.net.MacDiscovery
import wtf.mahdi.agentloungecompanion.protocol.ErrorCode
import wtf.mahdi.agentloungecompanion.protocol.LoungeProtocol

/** Mac chosen for pairing: found by mDNS or typed in. */
data class PairTarget(val name: String, val host: String, val port: Int)

enum class PairError { BAD_CODE, NO_PAIRING, UNREACHABLE, BAD_ADDRESS }

enum class DiscoveryStatus { WAITING_FOR_PERMISSION, SEARCHING, FAILED }

@Stable
data class PairUiState(
    val macs: List<DiscoveredMac> = emptyList(),
    val discovery: DiscoveryStatus = DiscoveryStatus.SEARCHING,
    val target: PairTarget? = null,
    val showManual: Boolean = false,
    val manualHost: String = "",
    val manualPort: String = LoungeProtocol.DEFAULT_PORT.toString(),
    val code: String = "",
    val deviceName: String = "",
    val isPairing: Boolean = false,
    val error: PairError? = null,
    val errorDetail: String? = null,
    /** The Mac removed this phone; shown once on the pair screen. */
    val pairingLost: Boolean = false,
) {
    val canPair: Boolean get() = target != null && code.length == CODE_LENGTH && !isPairing

    companion object {
        const val CODE_LENGTH = 6
        val EMPTY = PairUiState()
    }
}

sealed interface PairAction {
    data class PermissionChanged(val granted: Boolean) : PairAction
    data class SelectMac(val mac: DiscoveredMac) : PairAction
    data object ToggleManual : PairAction
    data class ManualHostChanged(val text: String) : PairAction
    data class ManualPortChanged(val text: String) : PairAction
    data object UseManualAddress : PairAction
    data class CodeChanged(val text: String) : PairAction
    data class DeviceNameChanged(val text: String) : PairAction
    data object Pair : PairAction
    data object ChangeMac : PairAction
}

/** Form part of the state, owned here. Discovery results come from [MacDiscovery]. */
private data class PairForm(
    val target: PairTarget? = null,
    val showManual: Boolean = false,
    val manualHost: String = "",
    val manualPort: String = LoungeProtocol.DEFAULT_PORT.toString(),
    val code: String = "",
    val deviceName: String = "",
    val isPairing: Boolean = false,
    val error: PairError? = null,
    val errorDetail: String? = null,
)

private data class DiscoveryResult(val macs: List<DiscoveredMac>, val status: DiscoveryStatus)

@OptIn(ExperimentalCoroutinesApi::class)
class PairViewModel(
    private val discovery: MacDiscovery,
    private val connection: LoungeConnection,
    defaultDeviceName: String,
) : ViewModel() {

    private val _granted = MutableStateFlow(false)
    private val _form = MutableStateFlow(PairForm(deviceName = defaultDeviceName))

    private val discoveryResults = _granted.flatMapLatest { granted ->
        if (!granted) {
            flowOf(DiscoveryResult(emptyList(), DiscoveryStatus.WAITING_FOR_PERMISSION))
        } else {
            discovery.discover()
                .map { DiscoveryResult(it, DiscoveryStatus.SEARCHING) }
                .onStart { emit(DiscoveryResult(emptyList(), DiscoveryStatus.SEARCHING)) }
                .catch { emit(DiscoveryResult(emptyList(), DiscoveryStatus.FAILED)) }
        }
    }

    val uiState: StateFlow<PairUiState> = combine(
        discoveryResults,
        _form,
        connection.pairingLost,
    ) { found, form, lost ->
        PairUiState(
            macs = found.macs,
            discovery = found.status,
            target = form.target,
            showManual = form.showManual,
            manualHost = form.manualHost,
            manualPort = form.manualPort,
            code = form.code,
            deviceName = form.deviceName,
            isPairing = form.isPairing,
            error = form.error,
            errorDetail = form.errorDetail,
            pairingLost = lost != null && form.target == null,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), PairUiState.EMPTY)

    fun onAction(action: PairAction) {
        when (action) {
            is PairAction.PermissionChanged -> _granted.value = action.granted
            is PairAction.SelectMac -> _form.update {
                it.copy(target = PairTarget(action.mac.name, action.mac.host, action.mac.port), code = "", error = null, errorDetail = null)
            }
            PairAction.ToggleManual -> _form.update { it.copy(showManual = !it.showManual) }
            is PairAction.ManualHostChanged -> _form.update { it.copy(manualHost = action.text.trim()) }
            is PairAction.ManualPortChanged -> _form.update { it.copy(manualPort = action.text.filter(Char::isDigit).take(5)) }
            PairAction.UseManualAddress -> useManualAddress()
            is PairAction.CodeChanged -> _form.update {
                it.copy(code = action.text.filter(Char::isDigit).take(PairUiState.CODE_LENGTH), error = null, errorDetail = null)
            }
            is PairAction.DeviceNameChanged -> _form.update { it.copy(deviceName = action.text.take(64)) }
            PairAction.Pair -> pair()
            PairAction.ChangeMac -> _form.update { it.copy(target = null, code = "", error = null, errorDetail = null) }
        }
    }

    private fun useManualAddress() {
        val form = _form.value
        val port = form.manualPort.toIntOrNull()
        if (form.manualHost.isEmpty() || port == null || port !in 1..65_535) {
            _form.update { it.copy(error = PairError.BAD_ADDRESS) }
            return
        }
        _form.update {
            it.copy(target = PairTarget(form.manualHost, form.manualHost, port), code = "", error = null, errorDetail = null)
        }
    }

    private fun pair() {
        val form = _form.value
        val target = form.target ?: return
        if (form.isPairing) return
        _form.update { it.copy(isPairing = true, error = null, errorDetail = null) }
        viewModelScope.launch {
            val outcome = connection.pair(target.host, target.port, form.code, form.deviceName.ifBlank { "Phone" })
            // On success the store has the Mac and the app shows the lounge.
            _form.update { current ->
                when (outcome) {
                    PairOutcome.Success -> current.copy(isPairing = false)
                    is PairOutcome.Refused -> current.copy(
                        isPairing = false,
                        code = "",
                        error = if (outcome.code == ErrorCode.BAD_CODE) PairError.BAD_CODE else PairError.NO_PAIRING,
                    )
                    is PairOutcome.Failed -> current.copy(isPairing = false, error = PairError.UNREACHABLE, errorDetail = outcome.reason)
                }
            }
        }
    }
}
