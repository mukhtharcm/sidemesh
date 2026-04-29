import { Command } from "commander";
import nodePath from "node:path";
import { fileURLToPath } from "node:url";

import {
  loadConfig,
  readResolvedPersistedConfig,
  rotatePersistedToken,
} from "./config.js";
import {
  persistedConfigFromNodeConfig,
  redactPersistedConfig,
} from "./config-store.js";
import { runDoctor } from "./doctor.js";
import { buildPairInfo } from "./pair.js";
import { startServer } from "./server.js";
import { runSetup } from "./setup.js";

export async function main(argv = process.argv): Promise<void> {
  const program = new Command();
  program
    .name("sidemesh")
    .description("Sidemesh daemon and setup tools")
    .showHelpAfterError();

  const withConfigOption = (command: Command) =>
    command.option("-c, --config <path>", "path to the Sidemesh config file");

  withConfigOption(
    program
      .command("daemon")
      .description("start the Sidemesh daemon")
      .action(async (options: { config?: string }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: true,
        });
        await startServer(config);
      }),
  );

  withConfigOption(
    program
      .command("setup")
      .description("create or update the persisted Sidemesh config")
      .option("--dev", "include internal test providers in the setup wizard")
      .action(async (options: { config?: string; dev?: boolean }) => {
        await runSetup({
          configPath: options.config,
          includeDevProviders: options.dev,
        });
      }),
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
        const daemonReachable = await checkHealth(
          `http://127.0.0.1:${config.port}/healthz`,
        );
        const payload = {
          configPath: config.configPath,
          configExists: config.configExists,
          label: config.label,
          port: config.port,
          stateDir: config.stateDir,
          terminal: config.terminal,
          defaultProvider: config.defaultProviderKind,
          providers: config.providers.map((provider) => provider.kind),
          tokenSource: config.tokenSource,
          tokenFingerprint: pairInfo.tokenFingerprint,
          daemonReachable,
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
        console.log(`Default provider: ${payload.defaultProvider}`);
        console.log(`Providers: ${payload.providers.join(", ")}`);
        console.log(`Token: ${payload.tokenFingerprint} (${payload.tokenSource})`);
        console.log(
          `Daemon: ${payload.daemonReachable ? "reachable" : "not reachable"} on http://127.0.0.1:${payload.port}/healthz`,
        );
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
      .action(async (options: { config?: string; json?: boolean }) => {
        const config = await loadConfig({
          configPath: options.config,
          persistGeneratedToken: true,
        });
        const pairInfo = buildPairInfo(config);
        if (options.json) {
          console.log(JSON.stringify(pairInfo, null, 2));
          return;
        }
        console.log(`Label: ${pairInfo.label}`);
        console.log(`Token: ${pairInfo.token}`);
        console.log(`Config: ${pairInfo.configPath}`);
        console.log("Base URLs:");
        for (const entry of pairInfo.addresses) {
          console.log(`- ${entry.url} [${entry.kind}]`);
        }
      }),
  );

  if (argv.length <= 2) {
    program.outputHelp();
    return;
  }

  await program.parseAsync(argv);
}

export async function runDaemonCommand(options: {
  configPath?: string | null;
} = {}): Promise<void> {
  const config = await loadConfig({
    configPath: options.configPath ?? null,
    persistGeneratedToken: true,
  });
  await startServer(config);
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

async function checkHealth(url: string): Promise<boolean> {
  try {
    const response = await fetch(url);
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
  return nodePath.resolve(entry) === fileURLToPath(import.meta.url);
}
