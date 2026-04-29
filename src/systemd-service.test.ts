import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  renderServiceEnv,
  renderServiceLauncher,
  renderSystemdUnit,
  resolveServicePaths,
} from "./systemd-service.js";
import type { NodeConfig } from "./types.js";

describe("systemd service rendering", () => {
  it("renders unit, launcher, and private env content", () => {
    const config: NodeConfig = {
      label: "Lab Node",
      port: 8899,
      token: "test-token",
      tokenSource: "file",
      provider: { kind: "codex", bin: "codex" },
      providers: [{ kind: "codex", bin: "codex" }],
      defaultProviderKind: "codex",
      stateDir: "/root/.sidemesh",
      terminal: { enabled: true, shell: "/bin/zsh", requirePty: false },
      configPath: "/root/.sidemesh/config.json",
      configExists: true,
    };
    const paths = resolveServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: "/root/.nvm/versions/node/v24.14.0/bin/node",
    });

    assert.equal(paths.unitPath, "/etc/systemd/system/sidemesh-test.service");
    assert.equal(paths.envPath, "/etc/sidemesh/sidemesh-test.env");
    assert.equal(paths.launcherPath, "/etc/sidemesh/sidemesh-test.sh");

    const unit = renderSystemdUnit(paths);
    assert.match(unit, /EnvironmentFile=\/etc\/sidemesh\/sidemesh-test\.env/);
    assert.match(unit, /ExecStart=\/etc\/sidemesh\/sidemesh-test\.sh/);
    assert.match(unit, /Restart=always/);

    const launcher = renderServiceLauncher(paths, config);
    assert.match(launcher, /dist\/cli\.js' daemon --config/);
    assert.match(launcher, /\/root\/\.sidemesh\/config\.json/);

    const env = renderServiceEnv(config);
    assert.match(env, /SIDEMESH_TOKEN=test-token/);
    assert.match(env, /SIDEMESH_TERMINAL=1/);
    assert.match(env, /SIDEMESH_TERMINAL_SHELL=\/bin\/zsh/);
    assert.match(env, /SIDEMESH_LABEL="Lab Node"/);
  });
});
