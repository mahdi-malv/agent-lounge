package wtf.mahdi.agentloungecompanion.ui

import android.app.Application
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import wtf.mahdi.agentloungecompanion.AppContainer
import wtf.mahdi.agentloungecompanion.Permissions
import wtf.mahdi.agentloungecompanion.ui.lounge.LoungeScreen
import wtf.mahdi.agentloungecompanion.ui.pair.PairScreen
import wtf.mahdi.agentloungecompanion.ui.settings.SettingsScreen

enum class Route { LOADING, PAIR, LOUNGE, SETTINGS }

data class PermissionState(val localNetwork: Boolean = true, val notifications: Boolean = true)

data class RootUiState(
    val route: Route = Route.LOADING,
    val permissions: PermissionState = PermissionState(),
) {
    companion object {
        val EMPTY = RootUiState()
    }
}

sealed interface RootAction {
    data object OpenSettings : RootAction
    data object CloseSettings : RootAction
    /** After a permission dialog or when the app comes back from system settings. */
    data object RecheckPermissions : RootAction
}

class RootViewModel(private val app: Application, private val container: AppContainer) : ViewModel() {
    private val _showSettings = MutableStateFlow(false)
    private val _permissions = MutableStateFlow(check())

    val uiState: StateFlow<RootUiState> = combine(
        container.store.pairedMac,
        _showSettings,
        _permissions,
    ) { mac, showSettings, permissions ->
        val route = when {
            mac == null -> Route.PAIR
            showSettings -> Route.SETTINGS
            else -> Route.LOUNGE
        }
        RootUiState(route = route, permissions = permissions)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), RootUiState.EMPTY)

    fun onAction(action: RootAction) {
        when (action) {
            RootAction.OpenSettings -> _showSettings.value = true
            RootAction.CloseSettings -> _showSettings.value = false
            RootAction.RecheckPermissions -> {
                val before = _permissions.value
                val now = check()
                _permissions.update { now }
                if (now.localNetwork && !before.localNetwork) container.connection.retry()
            }
        }
    }

    private fun check() = PermissionState(
        localNetwork = Permissions.hasLocalNetwork(app),
        notifications = Permissions.hasNotifications(app),
    )
}

@Composable
fun AppRoot(container: AppContainer, app: Application) {
    val viewModel: RootViewModel = viewModel { RootViewModel(app, container) }
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        viewModel.onAction(RootAction.RecheckPermissions)
    }
    val requestPermissions = { launcher.launch(missingPermissions(state.permissions)) }
    AskPermissionsOnce(state.permissions, requestPermissions)
    ObserveResume { viewModel.onAction(RootAction.RecheckPermissions) }

    BackHandler(enabled = state.route == Route.SETTINGS) { viewModel.onAction(RootAction.CloseSettings) }

    when (state.route) {
        Route.LOADING -> Box(Modifier.fillMaxSize())
        Route.PAIR -> PairScreen(
            container = container,
            localNetworkGranted = state.permissions.localNetwork,
            onRequestPermissions = requestPermissions,
        )
        Route.LOUNGE -> LoungeScreen(
            container = container,
            localNetworkGranted = state.permissions.localNetwork,
            onRequestPermissions = requestPermissions,
            onOpenSettings = { viewModel.onAction(RootAction.OpenSettings) },
        )
        Route.SETTINGS -> SettingsScreen(
            container = container,
            notificationsGranted = state.permissions.notifications,
            onRequestPermissions = requestPermissions,
            onBack = { viewModel.onAction(RootAction.CloseSettings) },
        )
    }
}

private fun missingPermissions(state: PermissionState): Array<String> = buildList {
    if (!state.localNetwork) add(Permissions.LOCAL_NETWORK)
    if (!state.notifications) add(android.Manifest.permission.POST_NOTIFICATIONS)
}.toTypedArray()

/** Asks for missing permissions once per screen session (not again after rotation). */
@Composable
private fun AskPermissionsOnce(state: PermissionState, request: () -> Unit) {
    var asked by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!asked && (!state.localNetwork || !state.notifications)) {
            asked = true
            request()
        }
    }
}

@Composable
private fun ObserveResume(onResume: () -> Unit) {
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) onResume() }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
}
