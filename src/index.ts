import { loadConfig } from "./config.js";
import { startServer } from "./server.js";

async function main(): Promise<void> {
  const config = loadConfig();
  await startServer(config);
}

main().catch((error) => {
  console.error("[sidemesh] failed to start");
  console.error(error);
  process.exit(1);
});
