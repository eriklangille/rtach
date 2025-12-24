/**
 * Debug what data rtach sends and trace reader behavior
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-debug-" + id + ".sock");
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
  console.log("Master ready\n");

  console.log("Connecting client...");
  const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  // Use a SINGLE persistent reader
  const reader = client.stdout!.getReader();
  const decoder = new TextDecoder();
  let totalBuffer = "";
  let pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;

  async function waitForMarker(marker: string, timeoutMs: number = 1000): Promise<void> {
    const start = Date.now();

    while (Date.now() - start < timeoutMs) {
      // Check if already in buffer
      if (totalBuffer.includes(marker)) {
        return;
      }

      // Read more
      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 50));
      if (!pendingRead) {
        pendingRead = reader.read();
      }

      const result = await Promise.race([pendingRead, timeout]);
      if (result === null) continue;

      pendingRead = null;
      if (result.done) throw new Error("Stream ended");
      if (result.value) {
        const chunk = decoder.decode(result.value, { stream: true });
        totalBuffer += chunk;
        console.log("  [READ] +" + result.value.length + " bytes, buffer now " + totalBuffer.length + " bytes");
      }
    }

    throw new Error("Timeout waiting for: " + marker);
  }

  // Read any initial data from rtach (scrollback, winsize packet)
  console.log("\nReading initial data (100ms)...");
  const initialStart = Date.now();
  while (Date.now() - initialStart < 100) {
    const timeout = new Promise<null>((r) => setTimeout(() => r(null), 20));
    if (!pendingRead) pendingRead = reader.read();
    const result = await Promise.race([pendingRead, timeout]);
    if (result === null) continue;
    pendingRead = null;
    if (result.done) break;
    if (result.value) {
      const chunk = decoder.decode(result.value, { stream: true });
      totalBuffer += chunk;
      console.log("  [INIT] +" + result.value.length + " bytes: " + JSON.stringify(chunk.slice(0, 50)));
    }
  }
  console.log("Initial buffer: " + totalBuffer.length + " bytes\n");

  // Now test with single persistent reader
  console.log("Testing with PERSISTENT reader (never released)...\n");

  for (let i = 0; i < 25; i++) {
    const marker = "MARK" + i + "END";
    const message = "X".repeat(50);

    client.stdin!.write(marker + message);
    client.stdin!.flush();

    try {
      await waitForMarker(marker);
      console.log("✓ Iteration " + i + ": OK (buffer: " + totalBuffer.length + " bytes)");
    } catch (e: any) {
      console.log("✗ Iteration " + i + ": FAILED - " + e.message);
      console.log("  Buffer content (last 200 chars): " + totalBuffer.slice(-200));
      break;
    }
  }

  reader.releaseLock();
  client.kill(9);
  await client.exited;
  master.kill(9);
  await master.exited;

  try {
    unlinkSync(socketPath);
  } catch {}
}

main().catch(console.error);
