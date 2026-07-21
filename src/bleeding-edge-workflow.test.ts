import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import nodePath from "node:path";
import { describe, it } from "node:test";

describe("Publish Bleeding Edge workflow", () => {
  it("publishes only successful same-repository main CI runs", async () => {
    const workflow = await readWorkflow();

    assert.match(workflow, /workflow_run:/);
    assert.match(workflow, /conclusion == 'success'/);
    assert.match(workflow, /workflow_run\.event == 'push'/);
    assert.match(workflow, /head_branch == 'main'/);
    assert.match(
      workflow,
      /head_repository\.full_name == github\.repository/,
    );
    assert.match(workflow, /refs\/heads\/bleeding-edge/);
    assert.match(
      workflow,
      /merge-base --is-ancestor "\$CANDIDATE_SHA" origin\/main/,
    );
    assert.match(
      workflow,
      /merge-base --is-ancestor "\$published_sha" "\$CANDIDATE_SHA"/,
    );
    assert.match(workflow, /cancel-in-progress: false/);
    assert.doesNotMatch(workflow, /git push[^\n]*--force/);
  });

  it("does not execute the candidate with its privileged token", async () => {
    const workflow = await readWorkflow();

    assert.match(workflow, /^permissions: \{\}$/m);
    assert.match(workflow, /^      contents: write$/m);
    assert.doesNotMatch(
      workflow,
      /ref:\s*\$\{\{\s*github\.event\.workflow_run\.head_sha/,
    );
    assert.doesNotMatch(workflow, /git checkout[^\n]*CANDIDATE_SHA/);
    assert.doesNotMatch(workflow, /(?:npm|node|npx|yarn|pnpm)\s+[^\n]*/);
  });
});

async function readWorkflow(): Promise<string> {
  return await readFile(
    nodePath.resolve(".github", "workflows", "publish-bleeding-edge.yml"),
    "utf8",
  );
}
