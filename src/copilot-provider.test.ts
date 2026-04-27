import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { CopilotAgentProvider } from "./copilot-provider.js";

describe("Copilot provider", () => {
  it("imports native Copilot CLI session-state history", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-native-"),
    );
    try {
      const sessionId = "11111111-2222-4333-8444-555555555555";
      const sessionDir = nodePath.join(dir, "native", sessionId);
      await mkdir(sessionDir, { recursive: true });
      await writeFile(
        nodePath.join(sessionDir, "workspace.yaml"),
        [
          `id: ${sessionId}`,
          `cwd: ${dir}`,
          "repository: your-org/sidemesh",
          "branch: main",
          "summary: Native Copilot Session",
          "created_at: 2026-04-01T00:00:00.000Z",
          "updated_at: 2026-04-01T00:05:00.000Z",
        ].join("\n"),
      );
      await writeFile(
        nodePath.join(sessionDir, "events.jsonl"),
        [
          JSON.stringify({
            type: "session.start",
            timestamp: "2026-04-01T00:00:00.000Z",
            data: { sessionId },
          }),
          JSON.stringify({
            type: "session.model_change",
            timestamp: "2026-04-01T00:00:01.000Z",
            data: { newModel: "gpt-5.2" },
          }),
          JSON.stringify({
            type: "user.message",
            id: "user-1",
            timestamp: "2026-04-01T00:01:00.000Z",
            data: { content: "hello native" },
          }),
          JSON.stringify({
            type: "assistant.message",
            id: "assistant-1",
            timestamp: "2026-04-01T00:01:05.000Z",
            data: { messageId: "assistant-message-1", content: "hello back" },
          }),
          JSON.stringify({
            type: "tool.execution_start",
            timestamp: "2026-04-01T00:01:06.000Z",
            data: {
              toolCallId: "tool-1",
              toolName: "view",
              arguments: { path: "README.md" },
            },
          }),
          JSON.stringify({
            type: "tool.execution_complete",
            timestamp: "2026-04-01T00:01:07.000Z",
            data: {
              toolCallId: "tool-1",
              toolName: "view",
              success: true,
              result: { content: "README contents" },
            },
          }),
        ].join("\n"),
      );

      const bin = nodePath.join(dir, "fake-copilot");
      await writeFile(
        bin,
        [
          "#!/usr/bin/env node",
          "const args = process.argv.slice(2);",
          "if (args.includes('--name') && args.some((arg) => arg.startsWith('--resume'))) {",
          "  console.error('name/resume conflict');",
          "  process.exit(1);",
          "}",
          "const prompt = args[args.indexOf('-p') + 1] || '';",
          "process.stdout.write('resumed: ' + prompt);",
        ].join("\n"),
      );
      await chmod(bin, 0o755);

      const provider = new CopilotAgentProvider({
        bin,
        stateDir: nodePath.join(dir, "state"),
        sessionStateDir: nodePath.join(dir, "native"),
      });
      await provider.start();

      const sessions = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      assert.equal(sessions.length, 1);
      assert.equal(sessions[0]?.id, sessionId);
      assert.equal(sessions[0]?.preview, "Native Copilot Session");
      assert.equal(sessions[0]?.cwd, dir);
      assert.equal(sessions[0]?.gitInfo?.branch, "main");

      const log = await provider.readSessionLog!(sessions[0]!);
      assert.equal(log.messages.length, 2);
      assert.equal(log.messages[0]?.text, "hello native");
      assert.equal(log.messages[1]?.text, "hello back");
      assert.equal(log.activities.length, 1);
      assert.equal(log.activities[0]?.type, "command");
      assert.equal(log.runtime?.model, "gpt-5.2");

      const completed = new Promise<void>((resolve) => {
        provider.on("liveEvent", (event) => {
          if (event.type === "turn_completed") resolve();
        });
      });
      await provider.submitInput!({
        sessionId,
        input: [{ type: "text", text: "continue native", text_elements: [] }],
        activeTurnId: null,
        overrides: {
          model: null,
          reasoningEffort: null,
          fastMode: null,
          approvalPolicy: null,
          sandboxMode: null,
          networkAccess: null,
          webSearch: null,
          profile: null,
        },
      });
      await completed;
      const updated = await provider.readSessionLog!(sessions[0]!);
      assert.equal(updated.messages.at(-1)?.text, "resumed: continue native");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("runs a text turn through a Copilot-compatible command", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-copilot-test-"));
    try {
      const bin = nodePath.join(dir, "fake-copilot");
      const argsPath = nodePath.join(dir, "args.json");
      await writeFile(
        bin,
        [
          "#!/usr/bin/env node",
          "const fs = require('node:fs');",
          "const args = process.argv.slice(2);",
          "if (args.includes('--version')) {",
          "  console.log('GitHub Copilot CLI 9.9.9');",
          "  process.exit(0);",
          "}",
          `fs.writeFileSync(${JSON.stringify(argsPath)}, JSON.stringify(args));`,
          "const prompt = args[args.indexOf('-p') + 1] || '';",
          "process.stdout.write('copilot says: ' + prompt);",
        ].join("\n"),
      );
      await chmod(bin, 0o755);

      const provider = new CopilotAgentProvider({
        bin,
        stateDir: nodePath.join(dir, "state"),
        sessionStateDir: nodePath.join(dir, "native-session-state"),
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
          model: null,
          reasoningEffort: null,
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
      assert.equal(log.runtime?.model, "auto");
      assert.equal(log.runtime?.reasoningEffort, undefined);

      const args = JSON.parse(await readFile(argsPath, "utf8")) as string[];
      assert.deepEqual(
        args.slice(args.indexOf("--model"), args.indexOf("--model") + 2),
        ["--model", "auto"],
      );
      assert.equal(args.includes("--effort"), false);

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

  it("exposes and forwards only the explicitly configured Copilot model", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-model-test-"),
    );
    try {
      const bin = nodePath.join(dir, "fake-copilot");
      const argsPath = nodePath.join(dir, "args.json");
      await writeFile(
        bin,
        [
          "#!/usr/bin/env node",
          "const fs = require('node:fs');",
          "const args = process.argv.slice(2);",
          "if (args[0] === 'help' && args[1] === 'config') {",
          "  console.log('  `model`: AI model to use for Copilot CLI.');",
          "  console.log('    - \"claude-haiku-4.5\"');",
          "  console.log('    - \"gpt-5.3-codex\"');",
          "  console.log('  `mouse`: whether to enable mouse support.');",
          "  process.exit(0);",
          "}",
          `fs.writeFileSync(${JSON.stringify(argsPath)}, JSON.stringify(args));`,
          "const prompt = args[args.indexOf('-p') + 1] || '';",
          "process.stdout.write('configured: ' + prompt);",
        ].join("\n"),
      );
      await chmod(bin, 0o755);

      const provider = new CopilotAgentProvider({
        bin,
        stateDir: nodePath.join(dir, "state"),
        sessionStateDir: nodePath.join(dir, "native-session-state"),
        configuredModel: "safe-test-model",
      });
      await provider.start();

      assert.equal(provider.capabilities.configuration.models, true);
      assert.equal(provider.capabilities.runtimeControls.model, true);
      const models = await provider.listModels!({
        cwd: dir,
        profile: null,
        provider: null,
      });
      assert.deepEqual(
        models.map((model) => ({
          model: model.model,
          displayName: model.displayName,
          source: model.source,
          isDefault: model.isDefault,
        })),
        [
          {
            model: "auto",
            displayName: "Auto",
            source: "cli-help",
            isDefault: false,
          },
          {
            model: "safe-test-model",
            displayName: "Safe Test Model",
            source: "config",
            isDefault: true,
          },
          {
            model: "claude-haiku-4.5",
            displayName: "Claude Haiku 4.5",
            source: "cli-help",
            isDefault: false,
          },
          {
            model: "gpt-5.3-codex",
            displayName: "Gpt 5.3 Codex",
            source: "cli-help",
            isDefault: false,
          },
        ],
      );

      const completed = new Promise<void>((resolve) => {
        provider.on("liveEvent", (event) => {
          if (event.type === "turn_completed") resolve();
        });
      });

      await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: {
          model: null,
          reasoningEffort: null,
          fastMode: null,
          approvalPolicy: null,
          sandboxMode: null,
          networkAccess: null,
          webSearch: null,
          profile: null,
        },
      });
      await completed;

      const args = JSON.parse(await readFile(argsPath, "utf8")) as string[];
      assert.deepEqual(
        args.slice(args.indexOf("--model"), args.indexOf("--model") + 2),
        ["--model", "safe-test-model"],
      );
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("falls back to auto instead of stale persisted Copilot model defaults", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-stale-model-test-"),
    );
    try {
      const bin = nodePath.join(dir, "fake-copilot");
      const stateDir = nodePath.join(dir, "state");
      const argsPath = nodePath.join(dir, "args.json");
      const sessionId = "stale-session";
      await mkdir(stateDir, { recursive: true });
      await writeFile(
        nodePath.join(stateDir, "sessions.json"),
        JSON.stringify({
          sessions: [
            {
              thread: {
                id: sessionId,
                name: null,
                preview: "stale",
                cwd: dir,
                createdAt: 1,
                updatedAt: 1,
                source: "copilot",
                path: nodePath.join(dir, "native-session-state", sessionId),
                status: { type: "idle" },
                turns: [],
              },
              messages: [],
              turns: [],
              runtime: {
                model: "gpt-5.2",
                modelProvider: "copilot",
                reasoningEffort: "medium",
              },
              nextSeq: 0,
              copilotSessionId: sessionId,
            },
          ],
        }),
      );
      await writeFile(
        bin,
        [
          "#!/usr/bin/env node",
          "const fs = require('node:fs');",
          "const args = process.argv.slice(2);",
          `fs.writeFileSync(${JSON.stringify(argsPath)}, JSON.stringify(args));`,
          "process.stdout.write('ok');",
        ].join("\n"),
      );
      await chmod(bin, 0o755);

      const provider = new CopilotAgentProvider({
        bin,
        stateDir,
        sessionStateDir: nodePath.join(dir, "native-session-state"),
      });
      await provider.start();

      const completed = new Promise<void>((resolve) => {
        provider.on("liveEvent", (event) => {
          if (event.type === "turn_completed") resolve();
        });
      });
      await provider.submitInput!({
        sessionId,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        activeTurnId: null,
        overrides: {
          model: null,
          reasoningEffort: null,
          fastMode: null,
          approvalPolicy: null,
          sandboxMode: null,
          networkAccess: null,
          webSearch: null,
          profile: null,
        },
      });
      await completed;

      const args = JSON.parse(await readFile(argsPath, "utf8")) as string[];
      assert.deepEqual(
        args.slice(args.indexOf("--model"), args.indexOf("--model") + 2),
        ["--model", "auto"],
      );
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
