package wtf.mahdi.agentloungecompanion.ui.lounge

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.ui.text.font.FontFamily
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import wtf.mahdi.agentloungecompanion.AppContainer
import wtf.mahdi.agentloungecompanion.R
import wtf.mahdi.agentloungecompanion.protocol.SessionState
import wtf.mahdi.agentloungecompanion.protocol.TaskStatus
import wtf.mahdi.agentloungecompanion.ui.components.Avatar
import wtf.mahdi.agentloungecompanion.ui.components.NoticeCard
import wtf.mahdi.agentloungecompanion.ui.components.stateLabel
import wtf.mahdi.agentloungecompanion.ui.theme.AgentLoungeCompanionTheme
import wtf.mahdi.agentloungecompanion.ui.theme.LoungeColors

@Composable
fun LoungeScreen(
    container: AppContainer,
    localNetworkGranted: Boolean,
    onRequestPermissions: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val viewModel: LoungeViewModel = viewModel {
        LoungeViewModel(container.connection, container.store.pairedMac, container.focusCardId)
    }
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val notConnected = stringResource(R.string.decide_not_connected)
    val promptSent = stringResource(R.string.prompt_sent)
    val promptFailed = stringResource(R.string.prompt_failed)
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            viewModel.events.collect { event ->
                when (event) {
                    LoungeEvent.NotConnected -> snackbar.showSnackbar(notConnected)
                    LoungeEvent.PromptSent -> snackbar.showSnackbar(promptSent)
                    is LoungeEvent.PromptFailed -> snackbar.showSnackbar(event.reason.ifEmpty { promptFailed })
                }
            }
        }
    }
    LoungeContent(
        state = state,
        snackbar = snackbar,
        localNetworkGranted = localNetworkGranted,
        onRequestPermissions = onRequestPermissions,
        onOpenSettings = onOpenSettings,
        onAction = viewModel::onAction,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoungeContent(
    state: LoungeUiState,
    snackbar: SnackbarHostState = remember { SnackbarHostState() },
    localNetworkGranted: Boolean,
    onRequestPermissions: () -> Unit,
    onOpenSettings: () -> Unit,
    onAction: (LoungeAction) -> Unit,
) {
    val listState = rememberLazyListState()
    // Scroll to the card of a tapped notification (Compose-owned list state).
    LaunchedEffect(state.focusIndex) {
        val index = state.focusIndex ?: return@LaunchedEffect
        listState.animateScrollToItem(index + 1) // +1: status row
        onAction(LoungeAction.FocusShown)
    }
    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            Column {
                TopAppBar(
                    title = {
                        Text(
                            state.macName.ifEmpty { stringResource(R.string.app_name) },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    actions = { TextButton(onClick = onOpenSettings) { Text(stringResource(R.string.settings_title)) } },
                )
                if (state.usage.isNotEmpty()) {
                    UsageStrip(
                        rows = state.usage,
                        stale = state.isStale,
                        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp),
                    )
                }
            }
        },
    ) { padding ->
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 12.dp,
                end = 12.dp,
                top = padding.calculateTopPadding(),
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item(key = "status") { StatusRow(state, onAction) }
            if (!localNetworkGranted) {
                item(key = "permission") {
                    NoticeCard(
                        text = stringResource(R.string.permission_local_network),
                        isWarning = true,
                        actionLabel = stringResource(R.string.action_allow),
                        onAction = onRequestPermissions,
                    )
                }
            }
            if (state.cards.isEmpty()) {
                item(key = "empty") { EmptyLounge(state) }
            }
            items(state.cards, key = { it.id }) { card ->
                AgentCard(
                    card = card,
                    expanded = card.id in state.expandedIds,
                    stale = state.isStale,
                    onClick = { onAction(LoungeAction.ToggleCard(card.id)) },
                    onDecide = { id, allow -> onAction(LoungeAction.Decide(id, allow)) },
                    onDraftChange = { text -> onAction(LoungeAction.DraftChanged(card.id, text)) },
                    onSendPrompt = { onAction(LoungeAction.SendPrompt(card.id)) },
                    modifier = Modifier.animateItem(),
                )
            }
        }
    }
}

@Composable
private fun UsageStrip(rows: List<UsageUi>, stale: Boolean, modifier: Modifier = Modifier) {
    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = modifier.graphicsLayer { alpha = if (stale) 0.5f else 1f },
    ) {
        rows.forEach { row ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    row.agent,
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.width(52.dp),
                )
                if (row.problem != null || row.windows.isEmpty()) {
                    Text(
                        row.problem ?: stringResource(R.string.usage_no_data),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    row.windows.forEachIndexed { index, window ->
                        if (index > 0) Spacer(Modifier.width(12.dp))
                        UsageGauge(window, Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun UsageGauge(window: UsageUi.WindowUi, modifier: Modifier = Modifier) {
    val color = when (window.level) {
        UsageUi.Level.OK -> LoungeColors.Running
        UsageUi.Level.HIGH -> LoungeColors.NeedsInput
        UsageUi.Level.CRITICAL -> LoungeColors.Error
    }
    val description = stringResource(R.string.cd_usage_window, window.label, window.left, window.resetsIn ?: "-")
    Column(modifier.semantics(mergeDescendants = true) { stateDescription = description }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(window.label, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Medium)
            Spacer(Modifier.width(6.dp))
            Text(window.left, style = MaterialTheme.typography.labelSmall, maxLines = 1)
            Spacer(Modifier.weight(1f))
            window.resetsIn?.let {
                Text(
                    "↻$it",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        }
        Spacer(Modifier.height(3.dp))
        LinearProgressIndicator(
            progress = { window.fraction },
            color = color,
            trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
            strokeCap = StrokeCap.Round,
            drawStopIndicator = {},
            gapSize = 0.dp,
            modifier = Modifier.fillMaxWidth().height(4.dp),
        )
    }
}

@Composable
private fun StatusRow(state: LoungeUiState, onAction: (LoungeAction) -> Unit) {
    val (color, text) = when (state.status) {
        LinkStatus.CONNECTED -> LoungeColors.Running to pluralStringResource(R.plurals.status_connected, state.cards.size, state.cards.size)
        LinkStatus.CONNECTING -> LoungeColors.NeedsInput to stringResource(R.string.status_connecting)
        LinkStatus.WAITING -> LoungeColors.Error to stringResource(R.string.status_waiting, state.retryInSeconds)
        LinkStatus.PAUSED -> LoungeColors.Idle to stringResource(R.string.status_paused)
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(text, style = MaterialTheme.typography.labelLarge)
            if (state.status == LinkStatus.WAITING && state.failureReason != null) {
                Text(
                    state.failureReason,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (state.status == LinkStatus.WAITING) {
            TextButton(onClick = { onAction(LoungeAction.Retry) }) { Text(stringResource(R.string.action_retry)) }
        }
    }
}

@Composable
private fun EmptyLounge(state: LoungeUiState) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxWidth().padding(top = 64.dp, start = 24.dp, end = 24.dp),
    ) {
        Avatar(state = SessionState.IDLE, color = LoungeColors.project(0), modifier = Modifier.size(64.dp, 76.dp))
        Text(
            if (state.status == LinkStatus.CONNECTED) stringResource(R.string.empty_title) else stringResource(R.string.empty_offline),
            style = MaterialTheme.typography.titleMedium,
        )
        Text(
            stringResource(R.string.empty_hint),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AgentCard(
    card: CardUi,
    expanded: Boolean,
    stale: Boolean,
    onClick: () -> Unit,
    onDecide: (requestId: String, allow: Boolean) -> Unit,
    onDraftChange: (String) -> Unit,
    onSendPrompt: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val border = when (card.state) {
        SessionState.NEEDS_INPUT -> BorderStroke(2.dp, LoungeColors.NeedsInput)
        SessionState.ERROR -> BorderStroke(1.dp, LoungeColors.Error.copy(alpha = 0.6f))
        else -> null
    }
    val expandedText = stringResource(if (expanded) R.string.cd_expanded else R.string.cd_collapsed)
    Card(
        onClick = onClick,
        border = border,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer { alpha = if (stale) 0.6f else 1f }
            .semantics {
                role = Role.Button
                stateDescription = expandedText
            },
    ) {
        Column(Modifier.padding(12.dp).animateContentSize()) {
            Row(verticalAlignment = Alignment.Top) {
                Avatar(state = card.state, color = LoungeColors.project(card.colorIndex), phaseSeconds = card.phaseSeconds)
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            card.title,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (card.elapsed.isNotEmpty()) {
                            Text(
                                card.elapsed,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    Text(
                        card.subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (card.state == SessionState.NEEDS_INPUT) LoungeColors.NeedsInput else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (expanded) 6 else 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        HostBadge(card.host)
                        ProgressLine(card, Modifier.weight(1f))
                    }
                }
            }
            card.approval?.let { approval -> ApprovalBox(approval, enabled = !stale, onDecide = onDecide) }
            if (expanded) {
                card.prompt?.let { prompt -> PromptField(prompt, enabled = !stale, onDraftChange, onSendPrompt) }
                CardDetails(card)
            }
        }
    }
}

/** Types a prompt into the session's Ghostty terminal on the Mac. */
@Composable
private fun PromptField(prompt: CardUi.PromptUi, enabled: Boolean, onDraftChange: (String) -> Unit, onSend: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(top = 10.dp)) {
        OutlinedTextField(
            value = prompt.draft,
            onValueChange = onDraftChange,
            placeholder = { Text(stringResource(R.string.prompt_hint)) },
            enabled = enabled && !prompt.isSending,
            maxLines = 5,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            modifier = Modifier.weight(1f),
        )
        Spacer(Modifier.width(8.dp))
        Button(onClick = onSend, enabled = enabled && prompt.canSend) {
            Text(stringResource(if (prompt.isSending) R.string.prompt_sending else R.string.action_send))
        }
    }
}

/** Claude permission dialog on the Mac, answered here. */
@Composable
private fun ApprovalBox(approval: CardUi.ApprovalUi, enabled: Boolean, onDecide: (String, Boolean) -> Unit) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = LoungeColors.NeedsInput.copy(alpha = 0.12f),
        modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
    ) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(R.string.approval_title, approval.title),
                style = MaterialTheme.typography.labelLarge,
            )
            approval.detail?.let { detail ->
                Surface(shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest) {
                    Text(
                        detail,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        maxLines = 8,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth().padding(8.dp),
                    )
                }
            }
            if (approval.isSent) {
                Text(
                    stringResource(R.string.approval_sent),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    OutlinedButton(
                        onClick = { onDecide(approval.id, false) },
                        enabled = enabled,
                        modifier = Modifier.weight(1f),
                    ) { Text(stringResource(R.string.action_deny)) }
                    Button(
                        onClick = { onDecide(approval.id, true) },
                        enabled = enabled,
                        modifier = Modifier.weight(1f),
                    ) { Text(stringResource(R.string.action_allow_once)) }
                }
            }
        }
    }
}

@Composable
private fun HostBadge(text: String) {
    if (text.isEmpty()) return
    Surface(
        shape = RoundedCornerShape(6.dp),
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
    ) {
        Text(text, style = MaterialTheme.typography.labelSmall, maxLines = 1, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

@Composable
private fun ProgressLine(card: CardUi, modifier: Modifier = Modifier) {
    val tint = LoungeColors.stateTint(card.state)
    val progress = card.progress
    when {
        progress != null -> Row(modifier, verticalAlignment = Alignment.CenterVertically) {
            LinearProgressIndicator(
                progress = { progress.fraction },
                color = tint,
                strokeCap = StrokeCap.Round,
                modifier = Modifier.width(48.dp).height(4.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                listOfNotNull("${progress.done}/${progress.total}", progress.label).joinToString(" · "),
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        card.state == SessionState.RUNNING -> LinearProgressIndicator(
            color = tint,
            strokeCap = StrokeCap.Round,
            modifier = modifier.height(3.dp),
        )
        else -> Text(
            stringResource(stateLabel(card.state)),
            style = MaterialTheme.typography.labelSmall,
            color = tint,
            modifier = modifier,
        )
    }
}

@Composable
private fun CardDetails(card: CardUi) {
    Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        card.modelLine?.let { DetailRow(stringResource(R.string.detail_model), it) }
        card.gitBranch?.let { DetailRow(stringResource(R.string.detail_branch), it) }
        if (card.cwd.isNotEmpty()) DetailRow(stringResource(R.string.detail_folder), card.cwd)
        if (card.elapsed.isNotEmpty()) DetailRow(stringResource(R.string.detail_running_for), card.elapsed)
        if (card.lastEventAgo.isNotEmpty()) DetailRow(stringResource(R.string.detail_last_event), stringResource(R.string.ago, card.lastEventAgo))
        if (card.subagentCount > 0) DetailRow(stringResource(R.string.detail_subagents), card.subagentCount.toString())
        card.context?.let { context ->
            DetailRow(stringResource(R.string.detail_context), context.text)
            LinearProgressIndicator(
                progress = { context.fraction },
                color = if (context.fraction > 0.8f) LoungeColors.NeedsInput else MaterialTheme.colorScheme.primary,
                strokeCap = StrokeCap.Round,
                modifier = Modifier.fillMaxWidth().height(4.dp),
            )
        }
        card.lastMessage?.let { message -> LastReply(card.title, message) }
        if (card.tasks.isNotEmpty()) {
            Text(stringResource(R.string.detail_tasks), style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(top = 4.dp))
            card.tasks.forEach { task -> TaskRow(task) }
        }
    }
}

/** Preview of the agent's last reply. Tap opens the full text in a scrollable sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LastReply(title: String, message: String) {
    var showSheet by rememberSaveable { mutableStateOf(false) }
    var overflows by remember(message) { mutableStateOf(false) }
    Surface(
        onClick = { showSheet = true },
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
    ) {
        Column(Modifier.padding(10.dp)) {
            Text(
                message,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 12,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { overflows = it.hasVisualOverflow },
            )
            if (overflows) {
                Text(
                    stringResource(R.string.action_read_all),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
    if (showSheet) {
        ModalBottomSheet(
            onDismissRequest = { showSheet = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 24.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    stringResource(R.string.detail_last_reply),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 12.dp),
                )
                SelectionContainer(Modifier.verticalScroll(rememberScrollState())) {
                    Text(message, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(96.dp),
        )
        Text(value, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun TaskRow(task: CardUi.TaskUi) {
    val (mark, color) = when (task.status) {
        TaskStatus.COMPLETED -> "✓" to LoungeColors.Running
        TaskStatus.IN_PROGRESS -> "●" to LoungeColors.NeedsInput
        TaskStatus.PENDING -> "○" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row {
        Text(mark, color = color, style = MaterialTheme.typography.bodySmall, modifier = Modifier.width(20.dp))
        Text(
            task.text,
            style = MaterialTheme.typography.bodySmall,
            color = if (task.status == TaskStatus.COMPLETED) MaterialTheme.colorScheme.onSurfaceVariant else Color.Unspecified,
        )
    }
}

private val previewCards = listOf(
    CardUi(
        id = "a", title = "claude-huddle · Phone app", subtitle = "Allow Bash: ./gradlew test?", host = "Ghostty",
        state = SessionState.NEEDS_INPUT, colorIndex = 0, phaseSeconds = 0f,
        progress = CardUi.ProgressUi(2, 5, "Writing tests"), elapsed = "42m", lastEventAgo = "5s",
        modelLine = "opus · high", gitBranch = "main", cwd = "/Users/me/code/claude-huddle", subagentCount = 0,
        context = CardUi.ContextUi("101k / 1M", 0.1f), lastMessage = null,
        tasks = listOf(CardUi.TaskUi("Protocol", TaskStatus.COMPLETED), CardUi.TaskUi("Writing tests", TaskStatus.IN_PROGRESS)),
        approval = CardUi.ApprovalUi("r1", "Run the unit tests", "./gradlew test", "Bash", isSent = false),
        prompt = CardUi.PromptUi("Also update the README", isSending = false),
    ),
    CardUi(
        id = "b", title = "api · Fix login", subtitle = "Editing AuthService.kt", host = "Codex · Zed",
        state = SessionState.RUNNING, colorIndex = 3, phaseSeconds = 1f, progress = null, elapsed = "8m",
        lastEventAgo = "1s", modelLine = null, gitBranch = null, cwd = "/Users/me/code/api", subagentCount = 2,
        context = null, lastMessage = null, tasks = emptyList(),
    ),
    CardUi(
        id = "c", title = "site", subtitle = "Deployed the preview. All checks pass.", host = "Claude.app",
        state = SessionState.IDLE, colorIndex = 1, phaseSeconds = 2f, progress = null, elapsed = "2h 10m",
        lastEventAgo = "4m", modelLine = "sonnet", gitBranch = "feature/x", cwd = "/Users/me/code/site", subagentCount = 0,
        context = null, lastMessage = "Deployed the preview. All checks pass.", tasks = emptyList(),
    ),
)

private val previewUsage = listOf(
    UsageUi(
        agent = "Claude", plan = "Max", problem = null,
        windows = listOf(
            UsageUi.WindowUi("5h", 0.12f, "88% left", "2h 10m", UsageUi.Level.OK),
            UsageUi.WindowUi("7d", 0.76f, "24% left", "3d 2h", UsageUi.Level.HIGH),
        ),
    ),
    UsageUi(
        agent = "Codex", plan = "Plus", problem = null,
        windows = listOf(
            UsageUi.WindowUi("5h", 0.02f, "98% left", "2h 29m", UsageUi.Level.OK),
            UsageUi.WindowUi("7d", 0.93f, "7% left", "2d 7h", UsageUi.Level.CRITICAL),
        ),
    ),
)

@Preview(showBackground = true)
@Composable
private fun LoungePreview() {
    AgentLoungeCompanionTheme {
        LoungeContent(
            state = LoungeUiState(macName = "Mahdi’s MacBook Pro", status = LinkStatus.CONNECTED, cards = previewCards, usage = previewUsage, expandedIds = setOf("a")),
            localNetworkGranted = true,
            onRequestPermissions = {},
            onOpenSettings = {},
            onAction = {},
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun LoungeOfflinePreview() {
    AgentLoungeCompanionTheme {
        LoungeContent(
            state = LoungeUiState(macName = "Studio", status = LinkStatus.WAITING, retryInSeconds = 8, failureReason = "Connection refused"),
            localNetworkGranted = false,
            onRequestPermissions = {},
            onOpenSettings = {},
            onAction = {},
        )
    }
}
