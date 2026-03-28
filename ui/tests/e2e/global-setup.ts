import { spawn, execSync } from "child_process";
import { rm } from "fs/promises";
import * as path from "path";
import * as net from "net";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const CORVO_BIN = path.resolve(__dirname, "../../../zig-out/bin/corvo");
const DATA_DIR = "/tmp/corvo-e2e-data";
const SERVER_PORT = 18080;
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

async function seedData() {
  const enqueue = (queue: string, payload: object) =>
    fetch(`${SERVER_URL}/api/v1/enqueue`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ queue, payload }),
    });

  // Seed queues with jobs.
  for (let i = 0; i < 5; i++) {
    await enqueue("emails", { to: `user${i}@test.com` });
    await enqueue("payments", { amount: i * 10 });
  }
  for (let i = 0; i < 3; i++) {
    await enqueue("reports", { type: "monthly" });
  }
}

export default async function globalSetup() {
  // Kill anything on the port, wipe data.
  console.log(`[e2e] Killing any process on :${SERVER_PORT}...`);
  try {
    execSync(`lsof -ti:${SERVER_PORT} | xargs kill -9`, { stdio: "ignore" });
    await new Promise((r) => setTimeout(r, 500));
  } catch {
    // Nothing was running.
  }

  await rm(DATA_DIR, { recursive: true, force: true });

  const server = spawn(CORVO_BIN, [
    "--data-dir", DATA_DIR,
    "--port", String(SERVER_PORT),
    "--max-conns", "64",
  ], { detached: false, stdio: "ignore" });

  server.on("error", (err) => {
    console.error("[e2e] Failed to start corvo server:", err.message);
    process.exit(1);
  });

  process.env._CORVO_E2E_SERVER_PID = String(server.pid);
  (globalThis as any).__corvoE2EServer = server;

  console.log(`[e2e] Started corvo server (pid ${server.pid}), waiting for :${SERVER_PORT}...`);
  await waitForPort(SERVER_PORT);
  console.log(`[e2e] Server ready`);

  console.log("[e2e] Seeding demo data...");
  await seedData();
  console.log("[e2e] Seed complete");
}
