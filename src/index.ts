import { loadConfig } from "./config.js";
import { startServer } from "./server.js";

const config = loadConfig();

startServer(config).catch((error) => {
  console.error("[sidemesh] failed to start");
  console.error(error);
  process.exit(1);
});
