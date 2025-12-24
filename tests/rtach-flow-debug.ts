/**
 * Debug data flow timing - is the write or read hanging?
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-flow-" + id + ".sock");
}

async function waitForSocket(path: string, timeoutMs: number = 5000): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const stat = statSync(path);
      if (stat.isSocket()) return true;
    } catch {}
    await Bun.sleep(50);
  }
  return false;
}

async function main() {
  const socketPath = uniqueSocketPath();

  console.log("Starting rtach master...");
  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);

  console.log("Connecting client...");
  const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  const reader = client.stdout!.getReader();
  const decoder = new TextDecoder();
  let totalBuffer = "";
  let pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;

  // Drain initial data
  await Bun.sleep(100);
  while (true) {
    const timeout = new Promise<null>((r) => setTimeout(() => r(null), 20));
    if (!pendingRead) pendingRead = reader.read();
    const result = await Promise.race([pendingRead, timeout]);
    if (result === null) break;
    pendingRead = null;
    if (result.done) break;
    if (result.value) {
      totalBuffer += decoder.decode(result.value, { stream: true });
    }
  }
  console.log("Initial buffer drained: " + totalBuffer.length + " bytes\n");

  for (let i = 0; i < 25; i++) {
    const marker = "M" + i + "E";
    const message = "X".repeat(20);
    const data = marker + message;

    // Time the write
    const writeStart = performance.now();
    client.stdin!.write(data);
    client.stdin!.flush();
    const writeTime = performance.now() - writeStart;

    // Time waiting for response
    const readStart = performance.now();
    let found = false;
    let readTime = 0;

    while (performance.now() - readStart < 500) {
      if (totalBuffer.includes(marker)) {
        found = true;
        readTime = performance.now() - readStart;
        break;
      }

      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 10));
      if (!pendingRead) pendingRead = reader.read();
      const result = await Promise.race([pendingRead, timeout]);

      if (result === null) continue;
      pendingRead = null;
      if (result.done) {
        console.log("  Stream ended!");
        break;
      }
      if (result.value) {
        totalBuffer += decoder.decode(result.value, { stream: true });
      }
    }

    if (found) {
      console.log("✓ " + i + ": write=" + writeTime.toFixed(1) + "ms, read=" + readTime.toFixed(1) + "ms");
    } else {
      console.log("✗ " + i + ": write=" + writeTime.toFixed(1) + "ms, READ TIMEOUT (500ms)");
      console.log("  Last 100 chars of buffer: " + totalBuffer.slice(-100));

      // Check if processes are still alive
      console.log("  Client running: " + (client.exitCode === null));
      console.log("  Master running: " + (master.exitCode === null));
      break;
    }
  }

  reader.releaseLock();
  client.kill(9);
  await client.exited;
  master.kill(9);
  await master.exited;

  try { unlinkSync(socketPath); } catch {}
}

main().catch(console.error);
