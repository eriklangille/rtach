/**
 * Test reader re-acquisition with rtach specifically.
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { existsSync, statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-bug-" + id + ".sock");
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

async function waitForMarker(
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
  console.log("Master ready at", socketPath);

  console.log("Connecting client...");
  const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  console.log("Testing reader re-acquisition with rtach...\n");

  for (let i = 0; i < 25; i++) {
    const marker = "MARKER_" + i;

    // Write marker
    client.stdin!.write(marker + "\n");
    client.stdin!.flush();

    // Try to read it back
    try {
      await waitForMarker(client, marker);
      console.log("✓ Iteration " + i + ": OK");
    } catch (e: any) {
      console.log("✗ Iteration " + i + ": FAILED - " + e.message);
      console.log("\n>>> ISSUE at iteration " + i + " <<<");
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
