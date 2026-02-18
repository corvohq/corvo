import { rm } from "fs/promises";

const DATA_DIR = "/tmp/corvo-e2e-data";

export default async function globalTeardown() {
  if (process.env._CORVO_E2E_EXTERNAL_SERVER) {
    // Server was already running before tests; leave it alone.
    return;
  }

  const pid = process.env._CORVO_E2E_SERVER_PID;
  if (pid) {
    try {
      process.kill(Number(pid), "SIGTERM");
      console.log(`[e2e] Stopped corvo server (pid ${pid})`);
    } catch {
      // Already gone.
    }
  }

  await rm(DATA_DIR, { recursive: true, force: true });
}
