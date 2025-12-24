/**
 * Test reader behavior matching exactly what benchmarks do.
 * This mimics connectAndWait + benchmark loop.
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-bug2-" + id + ".sock");
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

// This mimics the ORIGINAL waitForOutput that creates a new reader each time
async function waitForMarkerNewReader(
  proc: ReturnType<typeof spawn>,
  marker: string,
  timeoutMs: number = 1000
): Promise<string> {
  const reader = proc.stdout?.getReader();
  if (!reader) throw new Error("No reader");

  const decoder = new TextDecoder();
  let result = "";
  const start = Date.now();

  try {
    while (Date.now() - start < timeoutMs) {
      const timeoutPromise = new Promise<null>((r) => setTimeout(() => r(null), 50));
      const readResult = await Promise.race([reader.read(), timeoutPromise]);

      if (readResult === null) continue;
      if (readResult.done) break;
      if (readResult.value) {
        result += decoder.decode(readResult.value, { stream: true });
        if (result.includes(marker)) {
          return result;
        }
      }
    }
  } finally {
    reader.releaseLock();
  }

  throw new Error("Timeout waiting for: " + marker);
}

async function main() {
  const socketPath = uniqueSocketPath();

  console.log("Starting rtach master...");
  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);
  console.log("Master ready");

  console.log("Connecting client...");
  const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  // Step 1: connectAndWait equivalent - verify connection
  const connectMarker = "__CONNECT__";
  console.log("Verifying connection with connectAndWait pattern...");
  client.stdin!.write(connectMarker);
  client.stdin!.flush();
  await waitForMarkerNewReader(client, connectMarker);
  console.log("Connection verified (1 reader acquire/release)");

  // Step 2: Benchmark loop - many more reader acquire/releases
  console.log("\nStarting benchmark loop...\n");

  for (let i = 0; i < 25; i++) {
    const marker = "L" + i;
    const message = "X".repeat(64);

    client.stdin!.write(marker + message.slice(marker.length));
    client.stdin!.flush();

    try {
      await waitForMarkerNewReader(client, marker);
      console.log("✓ Iteration " + i + ": OK (total reader acquires: " + (i + 2) + ")");
    } catch (e: any) {
      console.log("✗ Iteration " + i + ": FAILED - " + e.message);
      console.log("\n>>> ISSUE at iteration " + i + " (after " + (i + 1) + " total reader acquires) <<<");
      break;
    }
  }

  client.kill(9);
  await client.exited;
  master.kill(9);
  await master.exited;

  try {
    unlinkSync(socketPath);
  } catch {}
}

main().catch(console.error);
