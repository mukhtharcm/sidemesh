import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { CopilotAgentProvider } from "./copilot-provider.js";

describe("Copilot provider", () => {
  it("runs a text turn through a Copilot-compatible command", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-copilot-test-"));
    try {
      const bin = nodePath.join(dir, "fake-copilot");
      await writeFile(
        bin,
        [
          "#!/usr/bin/env node",
          "const args = process.argv.slice(2);",
          "if (args.includes('--version')) {",
          "  console.log('GitHub Copilot CLI 9.9.9');",
          "  process.exit(0);",
          "}",
          "const prompt = args[args.indexOf('-p') + 1] || '';",
          "process.stdout.write('copilot says: ' + prompt);",
        ].join("\n"),
      );
      await chmod(bin, 0o755);

      const provider = new CopilotAgentProvider({
        bin,
        stateDir: nodePath.join(dir, "state"),
      });
      await provider.start();

      assert.equal(await provider.getVersion(), "GitHub Copilot CLI 9.9.9");

      const completed = new Promise<void>((resolve) => {
        provider.on("liveEvent", (event) => {
          if (event.type === "turn_completed") {
            resolve();
          }
        });
      });

      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: {
          model: "gpt-5.2",
          reasoningEffort: "medium",
          fastMode: null,
          approvalPolicy: null,
          sandboxMode: null,
          networkAccess: null,
          webSearch: null,
          profile: null,
        },
      });
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages.length, 2);
      assert.equal(log.messages[0]?.role, "user");
      assert.equal(log.messages[0]?.text, "hello");
      assert.equal(log.messages[1]?.role, "assistant");
      assert.equal(log.messages[1]?.text, "copilot says: hello");
      assert.equal(log.runtime?.modelProvider, "copilot");

      const sessions = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      assert.equal(sessions.length, 1);
      assert.equal(sessions[0]?.source, "copilot");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
