#!/usr/bin/env node

import { closeSync, openSync, realpathSync, writeSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { spawn } from "node:child_process";
import nodePath from "node:path";
import { createInterface } from "node:readline/promises";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

import { Command } from "commander";
import QRCode from "qrcode";

import {
  loadConfig,
  readResolvedPersistedConfig,
  rotatePersistedToken,
} from "./config.js";
import {
  persistedConfigFromNodeConfig,
  redactPersistedConfig,
} from "./config-store.js";
import {
  inspectDaemon,
  isPidAlive,
  removeDaemonState,
  writeDaemonState,
} from "./daemon-lifecycle.js";
import { runDoctor } from "./doctor.js";
import {
  DEFAULT_LAUNCHD_LABEL,
  installLaunchdService,
  isLaunchdServiceLoaded,
  launchdServiceStatus,
  restartLaunchdService,
  uninstallLaunchdService,
} from "./launchd-service.js";
import { buildPairInfo, type PairInfo } from "./pair.js";
import { startServer, type RunningServer } from "./server.js";
import { runSetup } from "./setup.js";
import {
  installSystemdService,
  isSystemdServiceActive,
  restartSystemdService,
  systemdServiceStatus,
  DEFAULT_SERVICE_NAME,
  uninstallSystemdService,
} from "./systemd-service.js";
import type { NodeConfig } from "./types.js";
import {
  applyUpdateChannelOverrideFromEnv,
  runSelfUpdate,
} from "./self-update.js";

export async function main(argv = process.argv): Promise<void> {
  const program = new Command();
  program
    .name("sidemesh")
    .description("Start, pair, and manage the Sidemesh daemon")
    .showHelpAfterError();
  program.addHelpText("after", "\nTypical first run:\n  sidemesh up\n");

  const withConfigOption = (command: Command) =>
    command.option("-c, --config <path>", "path to the Sidemesh config file");

  withConfigOption(
    program
      .command("daemon")
      .description("start the Sidemesh daemon in the foreground")
      .option("--allow-duplicate", "skip the local duplicate-daemon guard")
      .action(async (options: { config?: string; allowDuplicate?: boolean }) => {
        await runDaemonCommand({
          configPath: options.config,
          allowDuplicate: options.allowDuplicate === true,
        });
      }),
  );

  withConfigOption(
    program
      .command("start")
      .description("start the Sidemesh daemon in the background")
      .action(async (options: { config?: string }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: true,
        });
        await startDaemon(config, { configPath: options.config ?? null });
      }),
  );

  withConfigOption(
    program
      .command("up")
      .description(
        "create a default config if needed, start the daemon, and show pairing details",
      )
      .option("--no-qr", "skip terminal QR output")
      .action(async (options: { config?: string; qr?: boolean }) => {
        await runUpCommand({
          configPath: options.config,
          qr: options.qr !== false,
        });
      }),
  );

  withConfigOption(
    program
      .command("stop")
      .description("stop the managed Sidemesh daemon")
      .option("-y, --yes", "do not prompt before stopping")
      .action(async (options: { config?: string; yes?: boolean }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: false,
        });
        await stopDaemon(config, { yes: options.yes === true });
      }),
  );

  withConfigOption(
    program
      .command("restart")
      .description("restart the managed Sidemesh daemon")
      .option("-y, --yes", "do not prompt before restarting")
      .action(async (options: { config?: string; yes?: boolean }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: true,
        });
        await restartDaemon(config, {
          configPath: options.config ?? null,
          yes: options.yes === true,
        });
      }),
  );

  withConfigOption(
    program
      .command("self-update")
      .description("update the Sidemesh daemon to the latest version")
      .option("--package-dir <path>", "Sidemesh package directory")
      .option("--managed-service <name>", "managed service name (e.g. sidemesh)")
      .option("--dry-run", "show what would be updated without doing it")
      .option("-y, --yes", "do not prompt before updating")
      .action(async (options: {
        config?: string;
        packageDir?: string;
        managedService?: string;
        dryRun?: boolean;
        yes?: boolean;
      }) => {
        let config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: true,
        });
        config = applyUpdateChannelOverrideFromEnv(config);
        const result = await runSelfUpdate({
          config,
          packageDir: options.packageDir ?? null,
          managedService: options.managedService ?? null,
          dryRun: options.dryRun === true,
        });
        if (result.success) {
          console.log(
            `Updated ${result.oldVersion} → ${result.newVersion ?? result.oldVersion}`
          );
          console.log(`Log: ${result.logPath}`);
          process.exit(0);
        } else {
          console.error(`Update failed: ${result.error}`);
          if (result.restored) {
            console.log("Previous version restored.");
          }
          console.log(`Log: ${result.logPath}`);
          process.exit(1);
        }
      }),
  );

  const serviceCommand = program
    .command("service")
    .description("manage the host OS service wrapper");

  withConfigOption(
    serviceCommand
      .command("install")
      .description("install or update the OS service")
      .option(
        "--name <name>",
        "systemd service name or launchd label",
        defaultServiceName(),
      )
      .option("--package-dir <path>", "Sidemesh package directory")
      .option("--node-bin <path>", "Node binary used by the service")
      .option("--unit-file <path>", "systemd unit path")
      .option("--plist-file <path>", "macOS LaunchAgent plist path")
      .option("--service-env-file <path>", "service environment file path")
      .option("--launcher-file <path>", "service launcher script path")
      .option("--memory-high <size>", "soft cgroup memory pressure threshold, e.g. 2G")
      .option("--memory-max <size>", "hard cgroup memory cap, e.g. 3G")
      .option("--no-start", "write service files without starting/restarting")
      .option("-y, --yes", "do not prompt before overwriting/restarting")
      .action(
        async (options: {
          config?: string;
          name?: string;
          packageDir?: string;
          nodeBin?: string;
          unitFile?: string;
          plistFile?: string;
          serviceEnvFile?: string;
          launcherFile?: string;
          memoryHigh?: string;
          memoryMax?: string;
          start?: boolean;
          yes?: boolean;
        }) => {
          const config = await loadConfig({
            configPath: options.config,
            persistGeneratedToken: true,
          });
          await confirmDanger(
            `This will write a ${serviceBackendLabel()} service for Sidemesh and ${options.start === false ? "leave it stopped" : "restart it"}.`,
            options.yes === true,
          );
          if (process.platform === "darwin" && options.start !== false) {
            await prepareLaunchdInstall(config);
          }
          if (process.platform === "darwin") {
            const paths = await installLaunchdService(config, {
              label: options.name,
              packageDir: nodePath.resolve(options.packageDir ?? packageRoot()),
              nodeBin: nodePath.resolve(options.nodeBin ?? process.execPath),
              plistPath: options.plistFile ?? options.unitFile,
              envPath: options.serviceEnvFile,
              launcherPath: options.launcherFile,
              start: options.start !== false,
            });
            console.log(`Installed ${paths.label}`);
            console.log(`Plist: ${paths.plistPath}`);
            console.log(`Environment: ${paths.envPath}`);
            console.log(`Launcher: ${paths.launcherPath}`);
            if (options.start !== false) {
              const loaded = await isLaunchdServiceLoaded(paths.label);
              console.log(`Service: ${loaded ? "loaded" : "not loaded"}`);
            }
          } else {
            const paths = await installSystemdService(config, {
              serviceName: options.name,
              packageDir: nodePath.resolve(options.packageDir ?? packageRoot()),
              nodeBin: nodePath.resolve(options.nodeBin ?? process.execPath),
              unitPath: options.unitFile,
              envPath: options.serviceEnvFile,
              launcherPath: options.launcherFile,
              memoryHigh: options.memoryHigh,
              memoryMax: options.memoryMax,
              start: options.start !== false,
            });
            console.log(`Installed ${paths.serviceName}.service`);
            console.log(`Unit: ${paths.unitPath}`);
            console.log(`Environment: ${paths.envPath}`);
            console.log(`Launcher: ${paths.launcherPath}`);
            if (options.start !== false) {
              const active = await isSystemdServiceActive(paths.serviceName);
              console.log(`Service: ${active ? "active" : "not active"}`);
            }
          }
        },
      ),
  );

  serviceCommand
    .command("status")
    .description("show service status")
    .option(
      "--name <name>",
      "systemd service name or launchd label",
      defaultServiceName(),
    )
    .action(async (options: { name?: string }) => {
      process.stdout.write(
        process.platform === "darwin"
          ? await launchdServiceStatus(options.name)
          : await systemdServiceStatus(options.name),
      );
    });

  serviceCommand
    .command("restart")
    .description("restart the OS service")
    .option(
      "--name <name>",
      "systemd service name or launchd label",
      defaultServiceName(),
    )
    .option("-y, --yes", "do not prompt before restarting")
    .action(async (options: { name?: string; yes?: boolean }) => {
      await confirmDanger(
        `This will restart ${options.name ?? defaultServiceName()}. Active streams and integrated terminals will disconnect.`,
        options.yes === true,
      );
      if (process.platform === "darwin") {
        await restartLaunchdService(options.name);
        const loaded = await isLaunchdServiceLoaded(options.name);
        console.log(`${options.name ?? defaultServiceName()} is ${loaded ? "loaded" : "not loaded"}.`);
      } else {
        await restartSystemdService(options.name);
        const active = await isSystemdServiceActive(options.name);
        console.log(
          `${options.name ?? DEFAULT_SERVICE_NAME}.service is ${active ? "active" : "not active"}.`,
        );
      }
    });

  withConfigOption(
    serviceCommand
      .command("uninstall")
      .description("stop and remove the OS service wrapper")
      .option(
        "--name <name>",
        "systemd service name or launchd label",
        defaultServiceName(),
      )
      .option("--unit-file <path>", "systemd unit path")
      .option("--plist-file <path>", "macOS LaunchAgent plist path")
      .option("--service-env-file <path>", "service environment file path")
      .option("--launcher-file <path>", "service launcher script path")
      .option("--keep-files", "stop/disable the service without deleting generated files")
      .option("-y, --yes", "do not prompt before uninstalling")
      .action(
        async (options: {
          config?: string;
          name?: string;
          unitFile?: string;
          plistFile?: string;
          serviceEnvFile?: string;
          launcherFile?: string;
          keepFiles?: boolean;
          yes?: boolean;
        }) => {
          const config = await loadConfig({
            configPath: options.config,
            persistGeneratedToken: false,
          });
          await confirmDanger(
            `This will stop and uninstall ${options.name ?? defaultServiceName()}. Active streams and integrated terminals will disconnect.`,
            options.yes === true,
          );
          if (process.platform === "darwin") {
            const paths = await uninstallLaunchdService(config, {
              label: options.name,
              plistPath: options.plistFile ?? options.unitFile,
              envPath: options.serviceEnvFile,
              launcherPath: options.launcherFile,
              removeFiles: options.keepFiles !== true,
            });
            console.log(`Uninstalled ${paths.label}`);
            if (options.keepFiles === true) {
              console.log(`Kept plist: ${paths.plistPath}`);
              console.log(`Kept environment: ${paths.envPath}`);
              console.log(`Kept launcher: ${paths.launcherPath}`);
            } else {
              console.log(`Removed plist: ${paths.plistPath}`);
              console.log(`Removed environment: ${paths.envPath}`);
              console.log(`Removed launcher: ${paths.launcherPath}`);
            }
          } else {
            const paths = await uninstallSystemdService({
              serviceName: options.name,
              unitPath: options.unitFile,
              envPath: options.serviceEnvFile,
              launcherPath: options.launcherFile,
              removeFiles: options.keepFiles !== true,
            });
            console.log(`Uninstalled ${paths.serviceName}.service`);
            if (options.keepFiles === true) {
              console.log(`Kept unit: ${paths.unitPath}`);
              console.log(`Kept environment: ${paths.envPath}`);
              console.log(`Kept launcher: ${paths.launcherPath}`);
            } else {
              console.log(`Removed unit: ${paths.unitPath}`);
              console.log(`Removed environment: ${paths.envPath}`);
              console.log(`Removed launcher: ${paths.launcherPath}`);
            }
          }
        },
      ),
  );

  withConfigOption(
    program
      .command("setup")
      .description("create or update the persisted Sidemesh config for custom providers and host features")
      .option("--dev", "include internal test providers in the setup wizard")
      .option(
        "--advanced",
        "show advanced prompts for daemon port and state directory",
      )
      .action(
        async (options: { config?: string; dev?: boolean; advanced?: boolean }) => {
          await runSetup({
            configPath: options.config,
            includeDevProviders: options.dev,
            advanced: options.advanced === true,
          });
        },
      ),
  );

  withConfigOption(
    program
      .command("doctor")
      .description("run startup and provider diagnostics")
      .option("--json", "print JSON output")
      .action(async (options: { config?: string; json?: boolean }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: false,
        });
        const report = await runDoctor(config);
        if (options.json) {
          console.log(JSON.stringify(report, null, 2));
          return;
        }
        renderDoctorReport(report);
      }),
  );

  withConfigOption(
    program
      .command("status")
      .description("show the resolved daemon configuration and local health")
      .option("--json", "print JSON output")
      .action(async (options: { config?: string; json?: boolean }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: false,
        });
        const pairInfo = buildPairInfo(config);
        const daemon = await inspectDaemon(config);
        const payload = {
          configPath: config.configPath,
          configExists: config.configExists,
          label: config.label,
          port: config.port,
          stateDir: config.stateDir,
          terminal: config.terminal,
          portForwarding: config.portForwarding,
          defaultProvider: config.defaultProviderKind,
          providers: config.providers.map((provider) => provider.kind),
          tokenSource: config.tokenSource,
          tokenFingerprint: pairInfo.tokenFingerprint,
          daemonReachable: daemon.healthReachable,
          daemonStatePath: daemon.statePath,
          daemonState: daemon.state,
          daemonPidAlive: daemon.pidAlive,
          pairAddresses: pairInfo.addresses,
        };
        if (options.json) {
          console.log(JSON.stringify(payload, null, 2));
          return;
        }
        console.log(`Config: ${payload.configPath}`);
        console.log(`Label: ${payload.label}`);
        console.log(`Port: ${payload.port}`);
        console.log(`State dir: ${payload.stateDir}`);
        console.log(
          `Terminal: ${payload.terminal.enabled ? "enabled" : "disabled"}${
            payload.terminal.shell ? ` (${payload.terminal.shell})` : ""
          }`,
        );
        console.log(
          `Port forwarding: ${
            payload.portForwarding.enabled ? "enabled" : "disabled"
          }${
            payload.portForwarding.allowNonLoopbackTargets
              ? " (non-localhost targets allowed)"
              : ""
          }`,
        );
        console.log(`Default provider: ${payload.defaultProvider}`);
        console.log(`Providers: ${payload.providers.join(", ")}`);
        console.log(`Token: ${payload.tokenFingerprint} (${payload.tokenSource})`);
        console.log(
          `Daemon: ${payload.daemonReachable ? "reachable" : "not reachable"} on http://127.0.0.1:${payload.port}/healthz`,
        );
        if (daemon.state) {
          console.log(
            `Managed daemon: pid ${daemon.state.pid} (${daemon.pidAlive ? "alive" : "stale"}), state ${daemon.statePath}`,
          );
        } else {
          console.log(`Managed daemon: no state file at ${daemon.statePath}`);
        }
        if (pairInfo.addresses.length > 0) {
          console.log("Pair addresses:");
          for (const entry of pairInfo.addresses) {
            console.log(`- ${entry.url} [${entry.kind}]`);
          }
        }
      }),
  );

  withConfigOption(
    program
      .command("config")
      .description("inspect persisted or resolved config")
      .command("show")
      .option("--json", "print JSON output")
      .option("--persisted", "show persisted file contents instead of resolved config")
      .action(
        async (options: {
          config?: string;
          json?: boolean;
          persisted?: boolean;
        }) => {
          if (options.persisted) {
            const persisted = await readResolvedPersistedConfig({
              configPath: options.config,
            });
            const payload = {
              configPath: persisted.path,
              exists: persisted.exists,
              config: persisted.value
                ? redactPersistedConfig(persisted.value)
                : null,
            };
            if (options.json) {
              console.log(JSON.stringify(payload, null, 2));
              return;
            }
            console.log(`Config path: ${payload.configPath}`);
            console.log(`Exists: ${payload.exists ? "yes" : "no"}`);
            console.log(JSON.stringify(payload.config, null, 2));
            return;
          }
          const config = await loadConfig({
            configPath: options.config,
            persistGeneratedToken: false,
          });
          const payload = redactPersistedConfig(persistedConfigFromNodeConfig(config));
          if (options.json) {
            console.log(
              JSON.stringify(
                {
                  configPath: config.configPath,
                  configExists: config.configExists,
                  config: payload,
                },
                null,
                2,
              ),
            );
            return;
          }
          console.log(`Resolved config: ${config.configPath}`);
          console.log(JSON.stringify(payload, null, 2));
        },
      ),
  );

  withConfigOption(
    program
      .command("token")
      .description("manage the persisted shared token")
      .command("rotate")
      .option("--json", "print JSON output")
      .action(async (options: { config?: string; json?: boolean }) => {
        const config = await rotatePersistedToken({ configPath: options.config });
        const pairInfo = buildPairInfo(config);
        if (options.json) {
          console.log(
            JSON.stringify(
              {
                configPath: config.configPath,
                token: config.token,
                tokenFingerprint: pairInfo.tokenFingerprint,
              },
              null,
              2,
            ),
          );
          return;
        }
        console.log(`Rotated token in ${config.configPath}`);
        console.log(`Token: ${config.token}`);
      }),
  );

  withConfigOption(
    program
      .command("pair")
      .description("show the host details needed to add this daemon in the app")
      .option("--json", "print JSON output")
      .option("--no-qr", "skip terminal QR output")
      .action(
        async (options: { config?: string; json?: boolean; qr?: boolean }) => {
          const config = await loadConfig({
            configPath: options.config,
            persistGeneratedToken: true,
          });
          const pairInfo = buildPairInfo(config);
          if (options.json) {
            console.log(JSON.stringify(pairInfo, null, 2));
            return;
          }
          await printPairInfo(pairInfo, { qr: options.qr !== false });
        },
      ),
  );

  if (argv.length <= 2) {
    program.outputHelp();
    return;
  }

  await program.parseAsync(argv);
}

export async function runDaemonCommand(options: {
  configPath?: string | null;
  allowDuplicate?: boolean;
} = {}): Promise<void> {
  const config = await loadConfig({
    configPath: options.configPath ?? null,
    persistGeneratedToken: true,
  });
  if (options.allowDuplicate !== true) {
    await assertNoManagedDaemon(config);
  }
  let server: RunningServer | null = null;
  const startedAt = Date.now();
  server = await startServer(config);
  await writeDaemonState(config, {
    pid: process.pid,
    port: config.port,
    label: config.label,
    configPath: config.configPath,
    stateDir: config.stateDir,
    startedAt,
    command: process.argv,
  });
  registerShutdownHandlers(config, () => server);
}

async function runUpCommand(options: {
  configPath?: string | null;
  qr: boolean;
}): Promise<void> {
  const config = await loadConfig({
    configPath: options.configPath,
    persistGeneratedToken: true,
  });
  const daemon = await inspectDaemon(config);
  if (daemon.healthReachable) {
    const reachableConflict = explainReachableDaemonConflictForUp(config, daemon);
    if (reachableConflict) {
      throw new Error(reachableConflict);
    }
    console.log(
      `Sidemesh is already reachable on http://127.0.0.1:${config.port}/healthz.`,
    );
    await printPairInfo(buildPairInfo(config), { qr: options.qr });
    return;
  }

  const report = await runDoctor(config);
  const blockingChecks = findBlockingProviderChecks(report);
  if (blockingChecks.length > 0) {
    console.error(
      "Sidemesh could not start because a selected provider command is not ready.",
    );
    for (const entry of blockingChecks) {
      console.error("");
      console.error(`${entry.provider.displayName} (${entry.provider.kind})`);
      for (const check of entry.checks) {
        console.error(`${glyph(check.severity)} ${check.label}: ${check.detail}`);
        if (check.remedy) {
          console.error(`  fix: ${check.remedy}`);
        }
      }
    }
    console.error("");
    console.error(
      "Run `sidemesh doctor` for full diagnostics, or `sidemesh setup` to change providers.",
    );
    process.exitCode = 1;
    return;
  }

  await startDaemon(config, {
    configPath: options.configPath ?? null,
    showPairHint: false,
  });
  await printPairInfo(buildPairInfo(config), { qr: options.qr });
}

function renderDoctorReport(report: Awaited<ReturnType<typeof runDoctor>>): void {
  console.log(`Config: ${report.configPath}`);
  console.log(`Daemon health: ${report.daemonReachable ? "reachable" : "not reachable"} (${report.healthUrl})`);
  console.log("");
  for (const check of report.checks) {
    console.log(`${glyph(check.severity)} ${check.label}: ${check.detail}`);
    if (check.remedy) {
      console.log(`  fix: ${check.remedy}`);
    }
  }
  for (const provider of report.providers) {
    console.log("");
    console.log(`${provider.displayName} (${provider.kind})`);
    for (const check of provider.checks) {
      console.log(`${glyph(check.severity)} ${check.label}: ${check.detail}`);
      if (check.remedy) {
        console.log(`  fix: ${check.remedy}`);
      }
    }
  }
}

function glyph(severity: "ok" | "warn" | "error"): string {
  switch (severity) {
    case "ok":
      return "[ok]";
    case "warn":
      return "[warn]";
    case "error":
      return "[error]";
  }
}

async function assertNoManagedDaemon(config: NodeConfig): Promise<void> {
  const daemon = await inspectDaemon(config);
  if (daemon.pidAlive && daemon.healthReachable) {
    throw new Error(
      `Sidemesh is already running on port ${config.port} as pid ${daemon.state?.pid}. Run \`sidemesh status\`, \`sidemesh restart\`, or use \`sidemesh daemon --allow-duplicate\` only if you know why.`,
    );
  }
  if (daemon.pidAlive && daemon.state) {
    throw new Error(
      `Sidemesh state says pid ${daemon.state.pid} is still alive, but health did not respond. Refusing to start a second instance; run \`sidemesh stop --yes\` or inspect ${daemon.statePath}.`,
    );
  }
  if (daemon.state) {
    await removeDaemonState(config, daemon.state.pid);
  }
  if (daemon.healthReachable) {
    throw new Error(
      `Something is already responding on http://127.0.0.1:${config.port}/healthz. Refusing to start another daemon on the same port.`,
    );
  }
}

async function startDaemon(
  config: NodeConfig,
  options: { configPath?: string | null; showPairHint?: boolean },
): Promise<void> {
  await assertNoManagedDaemon(config);
  await mkdir(config.stateDir, { recursive: true });
  const logPath = nodePath.join(config.stateDir, "daemon.log");
  const logFd = openSync(logPath, "a");
  try {
    writeSync(logFd, `\n[sidemesh] starting at ${new Date().toISOString()}\n`);
    const invocation = daemonInvocation(options.configPath ?? config.configPath);
    const child = spawn(invocation.command, invocation.args, {
      cwd: process.cwd(),
      detached: true,
      env: {
        ...process.env,
        SIDEMESH_CONFIG: options.configPath ?? config.configPath,
      },
      stdio: ["ignore", logFd, logFd],
    });
    child.unref();

    const started = await waitForDaemonHealth(config.port, 12_000);
    if (!started) {
      throw new Error(
        `Daemon did not become healthy on port ${config.port}. Check ${logPath}.`,
      );
    }
    console.log(`Started Sidemesh daemon on port ${config.port} (pid ${child.pid}).`);
    console.log(`Logs: ${logPath}`);
    const pairInfo = buildPairInfo(config);
    if (options.showPairHint !== false && pairInfo.preferredAddress) {
      console.log(
        `Pair: ${pairInfo.preferredAddress.url} (run \`sidemesh pair\` for the QR and token)`,
      );
    }
  } finally {
    closeSync(logFd);
  }
}

async function stopDaemon(
  config: NodeConfig,
  options: { yes?: boolean },
): Promise<boolean> {
  const daemon = await inspectDaemon(config);
  if (!daemon.state) {
    if (daemon.healthReachable) {
      throw new Error(
        `A daemon responds on port ${config.port}, but no managed state file exists. Stop it manually or inspect the process using that port.`,
      );
    }
    console.log("Sidemesh daemon is not running.");
    return false;
  }
  if (!daemon.pidAlive) {
    await removeDaemonState(config, daemon.state.pid);
    console.log("Removed stale daemon state; no running daemon was found.");
    return false;
  }
  if (daemon.state.pid === process.pid) {
    throw new Error("Refusing to stop the current CLI process.");
  }
  await confirmDanger(
    `This will stop Sidemesh pid ${daemon.state.pid} on port ${daemon.state.port}. Active streams and integrated terminals will disconnect.`,
    options.yes === true,
  );
  try {
    process.kill(daemon.state.pid, "SIGTERM");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to stop daemon pid ${daemon.state.pid}: ${message}`);
  }
  const stopped = await waitForDaemonStop(config.port, daemon.state.pid, 10_000);
  if (!stopped) {
    throw new Error(
      `Daemon pid ${daemon.state.pid} did not stop within 10s. Inspect it before forcing termination.`,
    );
  }
  await removeDaemonState(config, daemon.state.pid);
  console.log(`Stopped Sidemesh daemon pid ${daemon.state.pid}.`);
  return true;
}

async function restartDaemon(
  config: NodeConfig,
  options: { configPath?: string | null; yes?: boolean },
): Promise<void> {
  const daemon = await inspectDaemon(config);
  if (daemon.pidAlive || daemon.healthReachable) {
    await stopDaemon(config, { yes: options.yes });
  } else if (daemon.state) {
    await removeDaemonState(config, daemon.state.pid);
  }
  await startDaemon(config, { configPath: options.configPath ?? config.configPath });
}

async function prepareLaunchdInstall(config: NodeConfig): Promise<void> {
  const daemon = await inspectDaemon(config);
  if (daemon.state && daemon.pidAlive) {
    await stopDaemon(config, { yes: true });
    return;
  }
  if (daemon.state) {
    await removeDaemonState(config, daemon.state.pid);
  }
  if (daemon.healthReachable) {
    throw new Error(
      `A daemon already responds on port ${config.port}, but no managed state file exists. Stop it before installing the LaunchAgent.`,
    );
  }
}

function daemonInvocation(configPath: string): { command: string; args: string[] } {
  const entry = fileURLToPath(import.meta.url);
  const args =
    entry.endsWith(".ts")
      ? ["--import", "tsx", entry, "daemon"]
      : [entry, "daemon"];
  args.push("--config", configPath);
  return { command: process.execPath, args };
}

function packageRoot(): string {
  return nodePath.resolve(nodePath.dirname(fileURLToPath(import.meta.url)), "..");
}

function defaultServiceName(): string {
  return process.platform === "darwin" ? DEFAULT_LAUNCHD_LABEL : DEFAULT_SERVICE_NAME;
}

function serviceBackendLabel(): string {
  return process.platform === "darwin" ? "macOS LaunchAgent" : "Linux systemd";
}

async function waitForDaemonHealth(
  port: number,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await checkHealth(`http://127.0.0.1:${port}/healthz`)) {
      return true;
    }
    await delay(250);
  }
  return false;
}

async function waitForDaemonStop(
  port: number,
  pid: number,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const alive = isPidAlive(pid);
    const reachable = await checkHealth(`http://127.0.0.1:${port}/healthz`);
    if (!alive && !reachable) {
      return true;
    }
    await delay(250);
  }
  return false;
}

async function confirmDanger(message: string, yes: boolean): Promise<void> {
  if (yes) return;
  if (!process.stdin.isTTY) {
    throw new Error(`${message} Pass --yes to confirm in a non-interactive shell.`);
  }
  const readline = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  try {
    const answer = await readline.question(`${message}\nContinue? [y/N] `);
    if (!["y", "yes"].includes(answer.trim().toLowerCase())) {
      throw new Error("Cancelled.");
    }
  } finally {
    readline.close();
  }
}

async function printPairInfo(
  pairInfo: PairInfo,
  options: {
    qr: boolean;
  },
): Promise<void> {
  console.log(`Label: ${pairInfo.label}`);
  console.log(`Token: ${pairInfo.token}`);
  console.log(`Config: ${pairInfo.configPath}`);
  console.log("Base URLs:");
  for (const entry of pairInfo.addresses) {
    console.log(`- ${entry.url} [${entry.kind}]`);
  }
  if (pairInfo.pairUrl == null) {
    return;
  }
  console.log(
    `\nScan to pair (${pairInfo.preferredAddress?.url ?? "preferred address"}):`,
  );
  if (options.qr) {
    console.log(
      await QRCode.toString(pairInfo.pairUrl, {
        type: "terminal",
        small: true,
      }),
    );
  }
  console.log(pairInfo.pairUrl);
}

function findBlockingProviderChecks(
  report: Awaited<ReturnType<typeof runDoctor>>,
): Array<{
  provider: Awaited<ReturnType<typeof runDoctor>>["providers"][number];
  checks: Awaited<ReturnType<typeof runDoctor>>["providers"][number]["checks"];
}> {
  return report.providers
    .map((provider) => ({
      provider,
      checks: provider.checks.filter(
        (check) =>
          check.severity === "error" &&
          (check.label === "binary" || check.label === "version"),
      ),
    }))
    .filter((entry) => entry.checks.length > 0);
}

export function explainReachableDaemonConflictForUp(
  config: Pick<NodeConfig, "configPath" | "port">,
  daemon: Awaited<ReturnType<typeof inspectDaemon>>,
): string | null {
  if (!daemon.healthReachable) {
    return null;
  }
  const healthUrl = `http://127.0.0.1:${config.port}/healthz`;
  if (!daemon.state) {
    return `A daemon is already reachable at ${healthUrl}, but no managed state file exists at ${daemon.statePath}. Refusing to guess its pairing token. Stop that process or start Sidemesh with this config before running \`sidemesh up\`.`;
  }
  if (!daemon.pidAlive) {
    return `A daemon is already reachable at ${healthUrl}, but the managed state file at ${daemon.statePath} is stale. Refusing to guess its pairing token. Run \`sidemesh stop --yes\` or remove the stale state before running \`sidemesh up\`.`;
  }
  if (daemon.state.configPath !== config.configPath) {
    return `A daemon is already reachable at ${healthUrl}, but it is managed by ${daemon.state.configPath}, not ${config.configPath}. Refusing to guess its pairing token.`;
  }
  return null;
}

function registerShutdownHandlers(
  config: NodeConfig,
  getServer: () => RunningServer | null,
): void {
  let shuttingDown = false;
  const shutdown = (signal: NodeJS.Signals) => {
    if (shuttingDown) return;
    shuttingDown = true;
    void (async () => {
      try {
        await closeWithDeadline(getServer(), 8_000);
      } finally {
        await removeDaemonState(config, process.pid).catch(() => undefined);
        process.exit(signal === "SIGINT" ? 130 : 0);
      }
    })();
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

async function closeWithDeadline(
  server: RunningServer | null,
  timeoutMs: number,
): Promise<void> {
  if (!server) return;
  let timeout: NodeJS.Timeout | null = null;
  try {
    await Promise.race([
      server.close(),
      new Promise<void>((resolve) => {
        timeout = setTimeout(resolve, timeoutMs);
        timeout.unref?.();
      }),
    ]);
  } finally {
    if (timeout) {
      clearTimeout(timeout);
    }
  }
}

async function checkHealth(url: string): Promise<boolean> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(1500) });
    return response.ok;
  } catch {
    return false;
  }
}

if (isDirectExecution()) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[sidemesh] ${message}`);
    process.exit(message === "Setup cancelled." ? 0 : 1);
  });
}

function isDirectExecution(): boolean {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  return realPathOrResolve(entry) === realPathOrResolve(fileURLToPath(import.meta.url));
}

function realPathOrResolve(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return nodePath.resolve(path);
  }
}
