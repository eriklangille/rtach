/**
 * Minimal reproduction of Bun reader re-acquisition bug.
 *
 * This script spawns `cat`, then repeatedly:
 * 1. Writes data to stdin
 * 2. Creates a reader
 * 3. Reads until we find our marker
 * 4. Releases the reader
 *
 * Run with: bun bun-reader-bug.ts
 */

import { spawn } from "bun";

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
  console.log("Spawning cat...");
  const proc = spawn(["cat"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  console.log("Testing reader re-acquisition...\n");

  for (let i = 0; i < 25; i++) {
    const marker = "MARKER_" + i;

    // Write marker
    proc.stdin!.write(marker + "\n");
    proc.stdin!.flush();

    // Try to read it back
    try {
      await waitForMarker(proc, marker);
      console.log("✓ Iteration " + i + ": OK (reader acquired/released " + (i + 1) + " times)");
    } catch (e: any) {
      console.log("✗ Iteration " + i + ": FAILED - " + e.message);
      console.log("\n>>> BUG CONFIRMED: Reader fails after " + i + " re-acquisitions <<<");
      break;
    }
  }

  proc.kill(9);
  await proc.exited;
}

main().catch(console.error);
