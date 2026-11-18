package wtf.mahdi.agentloungecompanion.ui.settings

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.selection.toggleable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import wtf.mahdi.agentloungecompanion.AppContainer
import wtf.mahdi.agentloungecompanion.R
import wtf.mahdi.agentloungecompanion.data.AppSettings
import wtf.mahdi.agentloungecompanion.protocol.AlertKind
import wtf.mahdi.agentloungecompanion.ui.components.NoticeCard
import wtf.mahdi.agentloungecompanion.ui.theme.AgentLoungeCompanionTheme

data class SettingsUiState(
    val macName: String = "",
    val macAddress: String = "",
    val settings: AppSettings = AppSettings.DEFAULT,
    val confirmForget: Boolean = false,
) {
    companion object {
        val EMPTY = SettingsUiState()
    }
}

sealed interface SettingsAction {
    data class SetBackground(val enabled: Boolean) : SettingsAction
    data class SetNotify(val kind: AlertKind, val enabled: Boolean) : SettingsAction
    data object AskForget : SettingsAction
    data object ConfirmForget : SettingsAction
    data object DismissForget : SettingsAction
}

class SettingsViewModel(private val container: AppContainer) : ViewModel() {
    private val _confirmForget = MutableStateFlow(false)

    val uiState: StateFlow<SettingsUiState> = combine(
        container.store.pairedMac,
        container.settings,
        _confirmForget,
    ) { mac, settings, confirm ->
        SettingsUiState(
            macName = mac?.name.orEmpty(),
            macAddress = mac?.let { "${it.host}:${it.port}" }.orEmpty(),
            settings = settings,
            confirmForget = confirm,
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), SettingsUiState.EMPTY)

    fun onAction(action: SettingsAction) {
        when (action) {
            is SettingsAction.SetBackground -> viewModelScope.launch { container.store.setBackgroundAlerts(action.enabled) }
            is SettingsAction.SetNotify -> viewModelScope.launch { container.store.setNotify(action.kind, action.enabled) }
            SettingsAction.AskForget -> _confirmForget.value = true
            SettingsAction.DismissForget -> _confirmForget.value = false
            SettingsAction.ConfirmForget -> {
                _confirmForget.value = false
                // The root shows the pair screen when the Mac is gone.
                viewModelScope.launch { container.connection.forget() }
            }
        }
    }
}

@Composable
fun SettingsScreen(
    container: AppContainer,
    notificationsGranted: Boolean,
    onRequestPermissions: () -> Unit,
    onBack: () -> Unit,
) {
    val viewModel: SettingsViewModel = viewModel { SettingsViewModel(container) }
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    SettingsContent(
        state = state,
        notificationsGranted = notificationsGranted,
        onRequestPermissions = onRequestPermissions,
        onOpenSystemSettings = {
            val intent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", context.packageName, null))
            }
            context.startActivity(intent)
        },
        onBack = onBack,
        onAction = viewModel::onAction,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsContent(
    state: SettingsUiState,
    notificationsGranted: Boolean,
    onRequestPermissions: () -> Unit,
    onOpenSystemSettings: () -> Unit,
    onBack: () -> Unit,
    onAction: (SettingsAction) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.action_back)) } },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 24.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item { SectionHeader(stringResource(R.string.settings_mac)) }
            item {
                ListItem(
                    headlineContent = { Text(state.macName) },
                    supportingContent = { Text(state.macAddress) },
                    trailingContent = {
                        TextButton(onClick = { onAction(SettingsAction.AskForget) }) {
                            Text(stringResource(R.string.settings_forget), color = MaterialTheme.colorScheme.error)
                        }
                    },
                )
            }

            item { SectionHeader(stringResource(R.string.settings_alerts)) }
            if (!notificationsGranted) {
                item {
                    NoticeCard(
                        text = stringResource(R.string.permission_notifications),
                        isWarning = true,
                        actionLabel = stringResource(R.string.action_allow),
                        onAction = onRequestPermissions,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
            }
            item {
                SwitchRow(
                    title = stringResource(R.string.settings_background),
                    detail = stringResource(R.string.settings_background_detail),
                    checked = state.settings.backgroundAlerts,
                    onChange = { onAction(SettingsAction.SetBackground(it)) },
                )
            }
            AlertKind.entries.forEach { kind ->
                item(key = kind.name) {
                    val (title, detail) = when (kind) {
                        AlertKind.NEEDS_INPUT -> R.string.settings_notify_needs_input to R.string.settings_notify_needs_input_detail
                        AlertKind.DONE -> R.string.settings_notify_done to R.string.settings_notify_done_detail
                        AlertKind.ERROR -> R.string.settings_notify_error to R.string.settings_notify_error_detail
                    }
                    SwitchRow(
                        title = stringResource(title),
                        detail = stringResource(detail),
                        checked = state.settings.notifies(kind),
                        onChange = { onAction(SettingsAction.SetNotify(kind, it)) },
                    )
                }
            }
            item {
                TextButton(onClick = onOpenSystemSettings, modifier = Modifier.padding(horizontal = 8.dp)) {
                    Text(stringResource(R.string.settings_sounds))
                }
            }

            item { SectionHeader(stringResource(R.string.settings_about)) }
            item {
                Text(
                    stringResource(R.string.settings_security_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
    }

    if (state.confirmForget) {
        AlertDialog(
            onDismissRequest = { onAction(SettingsAction.DismissForget) },
            title = { Text(stringResource(R.string.forget_title, state.macName)) },
            text = { Text(stringResource(R.string.forget_text)) },
            confirmButton = {
                TextButton(onClick = { onAction(SettingsAction.ConfirmForget) }) {
                    Text(stringResource(R.string.settings_forget), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { onAction(SettingsAction.DismissForget) }) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}

@Composable
private fun SwitchRow(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        trailingContent = { Switch(checked = checked, onCheckedChange = null) },
        modifier = Modifier.toggleable(value = checked, role = Role.Switch, onValueChange = onChange),
    )
}

@Preview(showBackground = true)
@Composable
private fun SettingsPreview() {
    AgentLoungeCompanionTheme {
        SettingsContent(
            state = SettingsUiState(macName = "Mahdi’s MacBook Pro", macAddress = "192.168.0.100:47822"),
            notificationsGranted = false,
            onRequestPermissions = {},
            onOpenSystemSettings = {},
            onBack = {},
            onAction = {},
        )
    }
}
