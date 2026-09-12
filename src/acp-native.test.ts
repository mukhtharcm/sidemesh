import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";
import { AcpAgentProvider } from "./acp-provider.js";
import { SessionStore } from "./session-store.js";

it("checks a selected ACP agent with an isolated home and no model prompt", {
  skip: !process.env.SIDEMESH_TEST_ACP_EXECUTABLE, timeout: 45_000,
}, async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-native-"));
  const store = await SessionStore.open(directory);
  const keys = ["HOME", "USERPROFILE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME"];
  const original = keys.map((key) => [key, process.env[key]] as const);
  for (const key of keys) process.env[key] = directory;
  const provider = new AcpAgentProvider({ agent: "native-check", executable: process.env.SIDEMESH_TEST_ACP_EXECUTABLE,
    args: JSON.parse(process.env.SIDEMESH_TEST_ACP_ARGS ?? "[]") as string[], cwd: directory, stateDir: directory,
  }, { sessionStore: store });
  let signInRequested = false;
  provider.on("liveEvent", (event) => {
    if (event.type === "action_opened" && event.action.userInput?.choices?.includes("Cancel sign-in")) {
      signInRequested = true;
      provider.respondToPendingAction(event.action, { answer: "Cancel sign-in", wasFreeform: false });
    }
  });
  try {
    await provider.start();
    try {
      const created = await provider.createSession({ cwd: directory, input: [], overrides: {
        model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
        sandboxMode: null, networkAccess: null, webSearch: null, profile: null,
      } });
      const snapshot = await provider.readSessionSnapshot(created.thread.id);
      assert.equal(snapshot.busy, false);
      assert.deepEqual(snapshot.messages, []);
      assert.ok(store.getProviderSession("acpx", created.thread.id)?.nativeId);
    } catch (error) {
      if (!signInRequested) throw error;
      assert.match(String(error), /auth|sign.in/i);
    }
    assert.match(await provider.getVersion() ?? "", /ACP 1/);
  } finally {
    await provider.close();
    store.close();
    for (const [key, value] of original) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(directory, { recursive: true, force: true });
  }
});
