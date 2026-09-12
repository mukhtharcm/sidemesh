// Generated from codex-cli 0.144.6; do not edit.
// Run: node scripts/generate-codex-protocol.mjs <codex-binary>
// Upstream: https://github.com/openai/codex (Apache-2.0).

// v2/ThreadReadResponse.ts
export type ThreadReadResponse = { thread: Thread, };

// v2/Thread.ts
export type Thread = {
/**
 * Identifier for this thread. Codex-generated thread IDs are UUIDv7.
 */
id: string,
/**
 * Optional implementation-specific thread data.
 */
extra: ThreadExtra | null,
/**
 * Session id shared by threads that belong to the same session tree.
 */
sessionId: string,
/**
 * Source thread id when this thread was created by forking another thread.
 */
forkedFromId: string | null,
/**
 * The ID of the parent thread. This will only be set if this thread is a subagent.
 */
parentThreadId: string | null,
/**
 * Usually the first user message in the thread, if available.
 */
preview: string,
/**
 * Whether the thread is ephemeral and should not be materialized on disk.
 */
ephemeral: boolean,
/**
 * Persisted thread history contract selected when this thread was created.
 */
historyMode: ThreadHistoryMode,
/**
 * Model provider used for this thread (for example, 'openai').
 */
modelProvider: string,
/**
 * Unix timestamp (in seconds) when the thread was created.
 */
createdAt: number,
/**
 * Unix timestamp (in seconds) when the thread was last updated.
 */
updatedAt: number,
/**
 * Unix timestamp (in seconds) used for thread recency ordering.
 */
recencyAt: number | null,
/**
 * Current runtime status for the thread.
 */
status: ThreadStatus,
/**
 * [UNSTABLE] Path to the thread on disk.
 */
path: string | null,
/**
 * Working directory captured for the thread.
 */
cwd: AbsolutePathBuf,
/**
 * Version of the CLI that created the thread.
 */
cliVersion: string,
/**
 * Origin of the thread (CLI, VSCode, codex exec, codex app-server, etc.).
 */
source: SessionSource,
/**
 * Optional analytics source classification for this thread.
 */
threadSource: ThreadSource | null,
/**
 * Optional random unique nickname assigned to an AgentControl-spawned sub-agent.
 */
agentNickname: string | null,
/**
 * Optional role (agent_role) assigned to an AgentControl-spawned sub-agent.
 */
agentRole: string | null,
/**
 * Optional Git metadata captured when the thread was created.
 */
gitInfo: GitInfo | null,
/**
 * Optional user-facing thread title.
 */
name: string | null,
/**
 * Only populated on `thread/resume`, `thread/rollback`, `thread/fork`, and `thread/read`
 * (when `includeTurns` is true) responses.
 * For all other responses and notifications returning a Thread,
 * the turns field will be an empty list.
 */
turns: Array<Turn>, };

// AbsolutePathBuf.ts
/**
 * A path that is guaranteed to be absolute and normalized (though it is not
 * guaranteed to be canonicalized or exist on the filesystem).
 *
 * IMPORTANT: When deserializing an `AbsolutePathBuf`, a base path must be set
 * using [AbsolutePathBufGuard::new]. If no base path is set, the
 * deserialization will fail unless the path being deserialized is already
 * absolute.
 */
export type AbsolutePathBuf = string;

// v2/GitInfo.ts
export type GitInfo = { sha: string | null, branch: string | null, originUrl: string | null, };

// v2/SessionSource.ts
export type SessionSource = "cli" | "vscode" | "exec" | "appServer" | { "custom": string } | { "subAgent": SubAgentSource } | "unknown";

// SubAgentSource.ts
export type SubAgentSource = "review" | "compact" | { "thread_spawn": { parent_thread_id: ThreadId, depth: number, agent_path: AgentPath | null, agent_nickname: string | null, agent_role: string | null, } } | "memory_consolidation" | { "other": string };

// AgentPath.ts
export type AgentPath = string;

// ThreadId.ts
/**
 * Identifier for a Codex thread.
 *
 * Codex-generated thread IDs are UUIDv7, and some use cases rely on that.
 */
export type ThreadId = string;

// v2/ThreadExtra.ts
/**
 * Extra app-server data for a thread.
 */
export type ThreadExtra = Record<string, never>;

// v2/ThreadHistoryMode.ts
export type ThreadHistoryMode = "legacy" | "paginated";

// v2/ThreadSource.ts
export type ThreadSource = string;

// v2/ThreadStatus.ts
export type ThreadStatus = { "type": "notLoaded" } | { "type": "idle" } | { "type": "systemError" } | { "type": "active", activeFlags: Array<ThreadActiveFlag>, };

// v2/ThreadActiveFlag.ts
export type ThreadActiveFlag = "waitingOnApproval" | "waitingOnUserInput";

// v2/Turn.ts
export type Turn = {
/**
 * Identifier for this turn. Codex-generated turn IDs are UUIDv7.
 */
id: string,
/**
 * Thread items currently included in this turn payload.
 */
items: Array<ThreadItem>,
/**
 * Describes how much of `items` has been loaded for this turn.
 */
itemsView: TurnItemsView, status: TurnStatus,
/**
 * Only populated when the Turn's status is failed.
 */
error: TurnError | null,
/**
 * Unix timestamp (in seconds) when the turn started.
 */
startedAt: number | null,
/**
 * Unix timestamp (in seconds) when the turn completed.
 */
completedAt: number | null,
/**
 * Duration between turn start and completion in milliseconds, if known.
 */
durationMs: number | null, };

// v2/ThreadItem.ts
export type ThreadItem = { "type": "userMessage", id: string, clientId: string | null, content: Array<UserInput>, } | { "type": "hookPrompt", id: string, fragments: Array<HookPromptFragment>, } | { "type": "agentMessage", id: string, text: string, phase: MessagePhase | null, memoryCitation: MemoryCitation | null, } | { "type": "plan", id: string, text: string, } | { "type": "reasoning", id: string, summary: Array<string>, content: Array<string>, } | { "type": "commandExecution", id: string,
/**
 * The command to be executed.
 */
command: string,
/**
 * The command's working directory.
 */
cwd: LegacyAppPathString,
/**
 * Identifier for the underlying PTY process (when available).
 */
processId: string | null, source: CommandExecutionSource, status: CommandExecutionStatus,
/**
 * A best-effort parsing of the command to understand the action(s) it will perform.
 * This returns a list of CommandAction objects because a single shell command may
 * be composed of many commands piped together.
 */
commandActions: Array<CommandAction>,
/**
 * The command's output, aggregated from stdout and stderr.
 */
aggregatedOutput: string | null,
/**
 * The command's exit code.
 */
exitCode: number | null,
/**
 * The duration of the command execution in milliseconds.
 */
durationMs: number | null, } | { "type": "fileChange", id: string, changes: Array<FileUpdateChange>, status: PatchApplyStatus, } | { "type": "mcpToolCall", id: string, server: string, tool: string, status: McpToolCallStatus, arguments: JsonValue, appContext: McpToolCallAppContext | null,
/**
 * Deprecated: use `appContext.resourceUri` instead.
 */
mcpAppResourceUri?: string, pluginId: string | null, result: McpToolCallResult | null, error: McpToolCallError | null,
/**
 * The duration of the MCP tool call in milliseconds.
 */
durationMs: number | null, } | { "type": "dynamicToolCall", id: string, namespace: string | null, tool: string, arguments: JsonValue, status: DynamicToolCallStatus, contentItems: Array<DynamicToolCallOutputContentItem> | null, success: boolean | null,
/**
 * The duration of the dynamic tool call in milliseconds.
 */
durationMs: number | null, } | { "type": "collabAgentToolCall",
/**
 * Unique identifier for this collab tool call.
 */
id: string,
/**
 * Name of the collab tool that was invoked.
 */
tool: CollabAgentTool,
/**
 * Current status of the collab tool call.
 */
status: CollabAgentToolCallStatus,
/**
 * Thread ID of the agent issuing the collab request.
 */
senderThreadId: string,
/**
 * Thread ID of the receiving agent, when applicable. In case of spawn operation,
 * this corresponds to the newly spawned agent.
 */
receiverThreadIds: Array<string>,
/**
 * Prompt text sent as part of the collab tool call, when available.
 */
prompt: string | null,
/**
 * Model requested for the spawned agent, when applicable.
 */
model: string | null,
/**
 * Reasoning effort requested for the spawned agent, when applicable.
 */
reasoningEffort: ReasoningEffort | null,
/**
 * Last known status of the target agents, when available.
 */
agentsStates: { [key in string]?: CollabAgentState }, } | { "type": "subAgentActivity", id: string, kind: SubAgentActivityKind, agentThreadId: string, agentPath: string, } | { "type": "webSearch" } & WebSearchItem | { "type": "imageView", id: string, path: LegacyAppPathString, } | { "type": "sleep", id: string, durationMs: number, } | { "type": "imageGeneration" } & ImageGenerationItem | { "type": "enteredReviewMode", id: string, review: string, } | { "type": "exitedReviewMode", id: string, review: string, } | { "type": "contextCompaction", id: string, };

// ImageGenerationItem.ts
export type ImageGenerationItem = { id: string, status: string, revisedPrompt: string | null, result: string, savedPath?: AbsolutePathBuf, };

// LegacyAppPathString.ts
/**
 * A UTF-8 path for preserving raw path compatibility at the app-server API
 * boundary while Codex migrates to [`PathUri`].
 *
 * Supports storing arbitrary strings read from the API and converting to and
 * from [`PathUri`] using an explicitly selected native path convention.
 *
 * When converting from [`PathUri`], "native" refers to the supplied
 * [`PathConvention`], which may be foreign to the operating system running
 * this process. The inner string is private so path-producing code must use a
 * path conversion method instead of bypassing the intended conversion
 * boundary. Non-UTF-8 paths are converted to UTF-8 lossily because this API
 * value is serialized as a JSON string.
 *
 * Deserialization accepts any UTF-8 string without interpreting or validating
 * it. That unrestricted construction path is intentionally available only to
 * serde: Codex-internal code cannot construct this type directly from a raw
 * `String` and is instead encouraged to convert through [`PathUri`] or
 * [`AbsolutePathBuf`]. Relative path text remains valid until an operation
 * such as [`Self::to_path_uri`] requires an absolute path.
 */
export type LegacyAppPathString = string;

// MessagePhase.ts
/**
 * Classifies an assistant message as interim commentary or final answer text.
 *
 * Providers do not emit this consistently, so callers must treat `None` as
 * "phase unknown" and keep compatibility behavior for legacy models.
 */
export type MessagePhase = "commentary" | "final_answer";

// ReasoningEffort.ts
/**
 * See https://platform.openai.com/docs/guides/reasoning?api-mode=responses#get-started-with-reasoning
 */
export type ReasoningEffort = string;

// WebSearchItem.ts
export type WebSearchItem = { id: string, query: string, action: WebSearchAction | null, };

// v2/WebSearchAction.ts
export type WebSearchAction = { "type": "search", query: string | null, queries: Array<string> | null, } | { "type": "openPage", url: string | null, } | { "type": "findInPage", url: string | null, pattern: string | null, } | { "type": "other" };

// serde_json/JsonValue.ts
export type JsonValue = number | string | boolean | Array<JsonValue> | { [key in string]?: JsonValue } | null;

// v2/CollabAgentState.ts
export type CollabAgentState = { status: CollabAgentStatus, message: string | null, };

// v2/CollabAgentStatus.ts
export type CollabAgentStatus = "pendingInit" | "running" | "interrupted" | "completed" | "errored" | "shutdown" | "notFound";

// v2/CollabAgentTool.ts
export type CollabAgentTool = "spawnAgent" | "sendInput" | "resumeAgent" | "wait" | "closeAgent";

// v2/CollabAgentToolCallStatus.ts
export type CollabAgentToolCallStatus = "inProgress" | "completed" | "failed";

// v2/CommandAction.ts
export type CommandAction = { "type": "read", command: string, name: string, path: AbsolutePathBuf, } | { "type": "listFiles", command: string, path: string | null, } | { "type": "search", command: string, query: string | null, path: string | null, } | { "type": "unknown", command: string, };

// v2/CommandExecutionSource.ts
export type CommandExecutionSource = "agent" | "userShell" | "unifiedExecStartup" | "unifiedExecInteraction";

// v2/CommandExecutionStatus.ts
export type CommandExecutionStatus = "inProgress" | "completed" | "failed" | "declined";

// v2/DynamicToolCallOutputContentItem.ts
export type DynamicToolCallOutputContentItem = { "type": "inputText", text: string, } | { "type": "inputImage", imageUrl: string, };

// v2/DynamicToolCallStatus.ts
export type DynamicToolCallStatus = "inProgress" | "completed" | "failed";

// v2/FileUpdateChange.ts
export type FileUpdateChange = { path: string, kind: PatchChangeKind, diff: string, };

// v2/PatchChangeKind.ts
export type PatchChangeKind = { "type": "add" } | { "type": "delete" } | { "type": "update", move_path: string | null, };

// v2/HookPromptFragment.ts
export type HookPromptFragment = { text: string, hookRunId: string, };

// v2/McpToolCallAppContext.ts
export type McpToolCallAppContext = { connectorId: string, linkId: string | null, resourceUri: string | null, appName: string | null, templateId: string | null, actionName: string | null, };

// v2/McpToolCallError.ts
export type McpToolCallError = { message: string, };

// v2/McpToolCallResult.ts
export type McpToolCallResult = { content: Array<JsonValue>, structuredContent: JsonValue | null, _meta: JsonValue | null, };

// v2/McpToolCallStatus.ts
export type McpToolCallStatus = "inProgress" | "completed" | "failed";

// v2/MemoryCitation.ts
export type MemoryCitation = { entries: Array<MemoryCitationEntry>, threadIds: Array<string>, };

// v2/MemoryCitationEntry.ts
export type MemoryCitationEntry = { path: string, lineStart: number, lineEnd: number, note: string, };

// v2/PatchApplyStatus.ts
export type PatchApplyStatus = "inProgress" | "completed" | "failed" | "declined";

// v2/SubAgentActivityKind.ts
export type SubAgentActivityKind = "started" | "interacted" | "interrupted";

// v2/UserInput.ts
export type UserInput = { "type": "text", text: string,
/**
 * UI-defined spans within `text` used to render or persist special elements.
 */
text_elements: Array<TextElement>, } | { "type": "image", detail?: ImageDetail, url: string, } | { "type": "localImage", detail?: ImageDetail, path: string, } | { "type": "skill", name: string, path: string, } | { "type": "mention", name: string, path: string, };

// ImageDetail.ts
export type ImageDetail = "auto" | "low" | "high" | "original";

// v2/TextElement.ts
export type TextElement = {
/**
 * Byte range in the parent `text` buffer that this element occupies.
 */
byteRange: ByteRange,
/**
 * Optional human-readable placeholder for the element, displayed in the UI.
 */
placeholder: string | null, };

// v2/ByteRange.ts
export type ByteRange = { start: number, end: number, };

// v2/TurnError.ts
export type TurnError = { message: string, codexErrorInfo: CodexErrorInfo | null, additionalDetails: string | null, };

// v2/CodexErrorInfo.ts
/**
 * This translation layer make sure that we expose codex error code in camel case.
 *
 * When an upstream HTTP status is available (for example, from the Responses API or a provider),
 * it is forwarded in `httpStatusCode` on the relevant `codexErrorInfo` variant.
 */
export type CodexErrorInfo = "contextWindowExceeded" | "sessionBudgetExceeded" | "usageLimitExceeded" | "serverOverloaded" | "cyberPolicy" | { "httpConnectionFailed": { httpStatusCode: number | null, } } | { "responseStreamConnectionFailed": { httpStatusCode: number | null, } } | "internalServerError" | "unauthorized" | "badRequest" | "threadRollbackFailed" | "sandboxError" | { "responseStreamDisconnected": { httpStatusCode: number | null, } } | { "responseTooManyFailedAttempts": { httpStatusCode: number | null, } } | { "activeTurnNotSteerable": { turnKind: NonSteerableTurnKind, } } | "other";

// v2/NonSteerableTurnKind.ts
export type NonSteerableTurnKind = "review" | "compact";

// v2/TurnItemsView.ts
export type TurnItemsView = "notLoaded" | "summary" | "full";

// v2/TurnStatus.ts
export type TurnStatus = "completed" | "interrupted" | "failed" | "inProgress";

// v2/TurnStartParams.ts
export type TurnStartParams = { threadId: string, clientUserMessageId?: string | null, input: Array<UserInput>,
/**
 * Optional metadata to enrich Codex's ResponsesAPI turn metadata.
 *
 * Entries are flattened into the JSON string sent as
 * `client_metadata["x-codex-turn-metadata"]` on ResponsesAPI HTTP and websocket requests.
 *
 * They are not sent as top-level ResponsesAPI `client_metadata` keys, and reserved keys
 * such as `session_id`, `thread_id`, `turn_id`, and `window_id` cannot be overridden.
 */
responsesapiClientMetadata?: { [key in string]?: string } | null,
/**
 * Optional client-provided context fragments keyed by an opaque source identifier.
 */
additionalContext?: { [key in string]?: AdditionalContextEntry } | null,
/**
 * Optional environments for this turn and subsequent turns.
 *
 * Omitted uses the thread sticky environments. Empty disables
 * environment access for this turn. Non-empty selects the first
 * environment as the current turn environment for this turn.
 */
environments?: Array<TurnEnvironmentParams> | null,
/**
 * Override the working directory for this turn and subsequent turns.
 */
cwd?: string | null,
/**
 * Replace the thread's runtime workspace roots for this turn and
 * subsequent turns. Paths must be absolute.
 */
runtimeWorkspaceRoots?: Array<AbsolutePathBuf> | null,
/**
 * Override the approval policy for this turn and subsequent turns.
 */
approvalPolicy?: AskForApproval | null,
/**
 * Override where approval requests are routed for review on this turn and
 * subsequent turns.
 */
approvalsReviewer?: ApprovalsReviewer | null,
/**
 * Override the sandbox policy for this turn and subsequent turns.
 */
sandboxPolicy?: SandboxPolicy | null,
/**
 * Select a named permissions profile id for this turn and subsequent
 * turns. Cannot be combined with `sandboxPolicy`.
 */
permissions?: string | null,
/**
 * Override the model for this turn and subsequent turns.
 */
model?: string | null,
/**
 * Override the service tier for this turn and subsequent turns.
 */
serviceTier?: string | null | null,
/**
 * Override the reasoning effort for this turn and subsequent turns.
 */
effort?: ReasoningEffort | null,
/**
 * Override the reasoning summary for this turn and subsequent turns.
 */
summary?: ReasoningSummary | null,
/**
 * Override the personality for this turn and subsequent turns.
 */
personality?: Personality | null,
/**
 * Optional JSON Schema used to constrain the final assistant message for
 * this turn.
 */
outputSchema?: JsonValue | null,
/**
 * EXPERIMENTAL - Set a pre-set collaboration mode.
 * Takes precedence over model, reasoning_effort, and developer instructions if set.
 *
 * For `collaboration_mode.settings.developer_instructions`, `null` means
 * "use the built-in instructions for the selected mode".
 */
collaborationMode?: CollaborationMode | null,
/**
 * @deprecated Ignored. Use `effort: "ultra"` for proactive multi-agent behavior.
 */
multiAgentMode?: MultiAgentMode | null, };

// CollaborationMode.ts
/**
 * Collaboration mode for a Codex session.
 */
export type CollaborationMode = { mode: ModeKind, settings: Settings, };

// ModeKind.ts
/**
 * Initial collaboration mode to use when the TUI starts.
 */
export type ModeKind = "plan" | "default";

// Settings.ts
/**
 * Settings for a collaboration mode.
 */
export type Settings = { model: string, reasoning_effort: ReasoningEffort | null, developer_instructions: string | null, };

// MultiAgentMode.ts
/**
 * Controls the effective multi-agent delegation instructions for a turn. `custom` means the
 * configured mode hint defines the policy instead of a built-in policy.
 */
export type MultiAgentMode = { "custom": string } | "explicitRequestOnly" | "proactive";

// Personality.ts
export type Personality = "none" | "friendly" | "pragmatic";

// ReasoningSummary.ts
/**
 * A summary of the reasoning performed by the model. This can be useful for
 * debugging and understanding the model's reasoning process.
 * See https://platform.openai.com/docs/guides/reasoning?api-mode=responses#reasoning-summaries
 */
export type ReasoningSummary = "auto" | "concise" | "detailed" | "none";

// v2/AdditionalContextEntry.ts
export type AdditionalContextEntry = { value: string, kind: AdditionalContextKind, };

// v2/AdditionalContextKind.ts
export type AdditionalContextKind = "untrusted" | "application";

// v2/ApprovalsReviewer.ts
/**
 * Configures who approval requests are routed to for review. Examples
 * include sandbox escapes, blocked network access, MCP approval prompts, and
 * ARC escalations. Defaults to `user`. `auto_review` uses a carefully
 * prompted subagent to gather relevant context and apply a risk-based
 * decision framework before approving or denying the request.
 */
export type ApprovalsReviewer = "user" | "auto_review" | "guardian_subagent";

// v2/AskForApproval.ts
export type AskForApproval = "untrusted" | "on-request" | { "granular": { sandbox_approval: boolean, rules: boolean, skill_approval: boolean, request_permissions: boolean, mcp_elicitations: boolean, } } | "never";

// v2/SandboxPolicy.ts
export type SandboxPolicy = { "type": "dangerFullAccess" } | { "type": "readOnly", networkAccess: boolean, } | { "type": "externalSandbox", networkAccess: NetworkAccess, } | { "type": "workspaceWrite", writableRoots: Array<AbsolutePathBuf>, networkAccess: boolean, excludeTmpdirEnvVar: boolean, excludeSlashTmp: boolean, };

// v2/NetworkAccess.ts
export type NetworkAccess = "restricted" | "enabled";

// v2/TurnEnvironmentParams.ts
export type TurnEnvironmentParams = { environmentId: string, cwd: LegacyAppPathString, };

// v2/TurnSteerParams.ts
export type TurnSteerParams = { threadId: string, clientUserMessageId?: string | null, input: Array<UserInput>,
/**
 * Optional metadata to enrich Codex's ResponsesAPI turn metadata.
 *
 * Entries are flattened into the JSON string sent as
 * `client_metadata["x-codex-turn-metadata"]` on ResponsesAPI HTTP and websocket requests.
 *
 * They are not sent as top-level ResponsesAPI `client_metadata` keys, and reserved keys
 * such as `session_id`, `thread_id`, `turn_id`, and `window_id` cannot be overridden.
 */
responsesapiClientMetadata?: { [key in string]?: string } | null,
/**
 * Optional client-provided context fragments keyed by an opaque source identifier.
 */
additionalContext?: { [key in string]?: AdditionalContextEntry } | null,
/**
 * Required active turn id precondition. The request fails when it does not
 * match the currently active turn.
 */
expectedTurnId: string, };
