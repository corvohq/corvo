import { spawn, execSync } from "child_process";
import { rm } from "fs/promises";
import * as path from "path";
import * as net from "net";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CORVO_BIN = path.resolve(__dirname, "../../../bin/corvo");
const DATA_DIR = "/tmp/corvo-e2e-data";
const SERVER_PORT = 8080;
const SERVER_URL = `http://localhost:${SERVER_PORT}`;

function waitForPort(port: number, timeout = 15_000): Promise<void> {
  const deadline = Date.now() + timeout;
  return new Promise((resolve, reject) => {
    function attempt() {
      const socket = net.connect(port, "127.0.0.1");
      socket.on("connect", () => {
        socket.destroy();
        resolve();
      });
      socket.on("error", () => {
        socket.destroy();
        if (Date.now() > deadline) {
          reject(new Error(`Port ${port} not ready after ${timeout}ms`));
        } else {
          setTimeout(attempt, 200);
        }
      });
    }
    attempt();
  });
}

export default async function globalSetup() {
  // Always start from a clean slate: kill anything on the port, wipe data.
  // This avoids stale state (e.g. leftover API keys) from previous test runs.
  console.log(`[e2e] Killing any process on :${SERVER_PORT}...`);
  try {
    execSync(`lsof -ti:${SERVER_PORT} | xargs kill -9`, { stdio: "ignore" });
    // Give the old process a moment to release the port.
    await new Promise((r) => setTimeout(r, 500));
  } catch {
    // Nothing was running — that's fine.
  }

  await rm(DATA_DIR, { recursive: true, force: true });

  const server = spawn(CORVO_BIN, [
    "server",
    "--data-dir", DATA_DIR,
    "--bind", `:${SERVER_PORT}`,
    "--log-level", "warn",
  ], { detached: false, stdio: "ignore" });

  server.on("error", (err) => {
    console.error("[e2e] Failed to start corvo server:", err.message);
    process.exit(1);
  });

  // Store PID so teardown can kill it.
  process.env._CORVO_E2E_SERVER_PID = String(server.pid);
  // Keep a reference so Node doesn't GC it.
  (globalThis as any).__corvoE2EServer = server;

  console.log(`[e2e] Started corvo server (pid ${server.pid}), waiting for :${SERVER_PORT}...`);
  await waitForPort(SERVER_PORT);
  console.log(`[e2e] Server ready`);

  // Seed demo data.
  console.log("[e2e] Seeding demo data...");
  try {
    execSync(
      `${CORVO_BIN} seed demo --count 20 --server ${SERVER_URL}`,
      { stdio: "pipe" },
    );
    console.log("[e2e] Seed complete");
  } catch (err: any) {
    console.warn("[e2e] Seed warning:", err.stderr?.toString() ?? err.message);
  }
}
