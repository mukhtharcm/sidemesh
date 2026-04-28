import { runDaemonCommand } from "./cli.js";

runDaemonCommand().catch((error) => {
  console.error("[sidemesh] failed to start");
  console.error(error);
  process.exit(1);
});
