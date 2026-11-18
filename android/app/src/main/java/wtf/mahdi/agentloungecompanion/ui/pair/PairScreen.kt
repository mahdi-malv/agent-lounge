package wtf.mahdi.agentloungecompanion.ui.pair

import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import wtf.mahdi.agentloungecompanion.AppContainer
import wtf.mahdi.agentloungecompanion.R
import wtf.mahdi.agentloungecompanion.net.DiscoveredMac
import wtf.mahdi.agentloungecompanion.ui.components.NoticeCard
import wtf.mahdi.agentloungecompanion.ui.theme.AgentLoungeCompanionTheme

@Composable
fun PairScreen(
    container: AppContainer,
    localNetworkGranted: Boolean,
    onRequestPermissions: () -> Unit,
) {
    val context = LocalContext.current
    val viewModel: PairViewModel = viewModel {
        val name = Settings.Global.getString(context.contentResolver, "device_name") ?: Build.MODEL
        PairViewModel(container.discovery, container.connection, name)
    }
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(localNetworkGranted) { viewModel.onAction(PairAction.PermissionChanged(localNetworkGranted)) }
    PairContent(
        state = state,
        localNetworkGranted = localNetworkGranted,
        onRequestPermissions = onRequestPermissions,
        onAction = viewModel::onAction,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PairContent(
    state: PairUiState,
    localNetworkGranted: Boolean,
    onRequestPermissions: () -> Unit,
    onAction: (PairAction) -> Unit,
) {
    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.pair_title)) }) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().imePadding(),
            contentPadding = PaddingValues(
                start = 16.dp,
                end = 16.dp,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (state.pairingLost) {
                item { NoticeCard(text = stringResource(R.string.pair_lost), isWarning = true) }
            }
            if (!localNetworkGranted) {
                item {
                    NoticeCard(
                        text = stringResource(R.string.permission_local_network),
                        isWarning = true,
                        actionLabel = stringResource(R.string.action_allow),
                        onAction = onRequestPermissions,
                    )
                }
            }
            val target = state.target
            if (target == null) {
                item {
                    Text(stringResource(R.string.pair_intro), style = MaterialTheme.typography.bodyMedium)
                }
                item { MacListHeader(state.discovery) }
                items(state.macs, key = { it.name }) { mac ->
                    MacRow(mac = mac, onClick = { onAction(PairAction.SelectMac(mac)) })
                }
                item { ManualEntry(state, onAction) }
            } else {
                item { TargetCard(target, onChange = { onAction(PairAction.ChangeMac) }) }
                item { CodeForm(state, onAction) }
            }
        }
    }
}

@Composable
private fun MacListHeader(status: DiscoveryStatus) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.pair_macs_header), style = MaterialTheme.typography.titleSmall)
        when (status) {
            DiscoveryStatus.SEARCHING -> {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(
                    stringResource(R.string.pair_searching),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            DiscoveryStatus.FAILED -> Text(
                stringResource(R.string.pair_discovery_failed),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
            DiscoveryStatus.WAITING_FOR_PERMISSION -> Text(
                stringResource(R.string.pair_discovery_needs_permission),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun MacRow(mac: DiscoveredMac, onClick: () -> Unit) {
    Card(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        ListItem(
            headlineContent = { Text(mac.name) },
            supportingContent = { Text("${mac.host}:${mac.port}") },
            colors = androidx.compose.material3.ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        )
    }
}

@Composable
private fun ManualEntry(state: PairUiState, onAction: (PairAction) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        HorizontalDivider()
        TextButton(onClick = { onAction(PairAction.ToggleManual) }) {
            Text(stringResource(if (state.showManual) R.string.pair_manual_hide else R.string.pair_manual_show))
        }
        if (state.showManual) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = state.manualHost,
                    onValueChange = { onAction(PairAction.ManualHostChanged(it)) },
                    label = { Text(stringResource(R.string.pair_manual_host)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = state.manualPort,
                    onValueChange = { onAction(PairAction.ManualPortChanged(it)) },
                    label = { Text(stringResource(R.string.pair_manual_port)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { onAction(PairAction.UseManualAddress) }),
                    modifier = Modifier.width(110.dp),
                )
            }
            if (state.error == PairError.BAD_ADDRESS) {
                Text(stringResource(R.string.pair_error_address), color = MaterialTheme.colorScheme.error)
            }
            Button(onClick = { onAction(PairAction.UseManualAddress) }) {
                Text(stringResource(R.string.action_continue))
            }
        }
    }
}

@Composable
private fun TargetCard(target: PairTarget, onChange: () -> Unit) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Row(modifier = Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(target.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    "${target.host}:${target.port}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                )
            }
            TextButton(onClick = onChange) { Text(stringResource(R.string.action_change)) }
        }
    }
}

@Composable
private fun CodeForm(state: PairUiState, onAction: (PairAction) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(R.string.pair_code_hint), style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = state.code,
            onValueChange = { onAction(PairAction.CodeChanged(it)) },
            label = { Text(stringResource(R.string.pair_code)) },
            singleLine = true,
            textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 28.sp, letterSpacing = 6.sp, textAlign = TextAlign.Center),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (state.canPair) onAction(PairAction.Pair) }),
            isError = state.error == PairError.BAD_CODE || state.error == PairError.NO_PAIRING,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = state.deviceName,
            onValueChange = { onAction(PairAction.DeviceNameChanged(it)) },
            label = { Text(stringResource(R.string.pair_device_name)) },
            supportingText = { Text(stringResource(R.string.pair_device_name_hint)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        state.error?.let { error ->
            val text = when (error) {
                PairError.BAD_CODE -> stringResource(R.string.pair_error_code)
                PairError.NO_PAIRING -> stringResource(R.string.pair_error_no_pairing)
                PairError.UNREACHABLE -> stringResource(R.string.pair_error_unreachable, state.errorDetail.orEmpty())
                PairError.BAD_ADDRESS -> stringResource(R.string.pair_error_address)
            }
            Text(text, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
        Button(
            onClick = { onAction(PairAction.Pair) },
            enabled = state.canPair,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (state.isPairing) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
            }
            Text(stringResource(R.string.action_pair))
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun PairListPreview() {
    AgentLoungeCompanionTheme {
        PairContent(
            state = PairUiState(
                macs = listOf(
                    DiscoveredMac("Mahdi’s MacBook Pro", "srv", "192.168.0.100", 47822),
                    DiscoveredMac("Studio", "srv2", "192.168.0.20", 47822),
                ),
            ),
            localNetworkGranted = true,
            onRequestPermissions = {},
            onAction = {},
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun PairCodePreview() {
    AgentLoungeCompanionTheme {
        PairContent(
            state = PairUiState(
                target = PairTarget("Mahdi’s MacBook Pro", "192.168.0.100", 47822),
                code = "034",
                deviceName = "Galaxy S26",
                error = PairError.BAD_CODE,
            ),
            localNetworkGranted = false,
            onRequestPermissions = {},
            onAction = {},
        )
    }
}
