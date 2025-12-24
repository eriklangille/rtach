/**
 * Test different message sizes to find the threshold
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-size-" + id + ".sock");
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

async function testWithSize(messageSize: number): Promise<number> {
  const socketPath = uniqueSocketPath();

  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);

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
  await Bun.sleep(50);
  while (true) {
    const timeout = new Promise<null>((r) => setTimeout(() => r(null), 10));
    if (!pendingRead) pendingRead = reader.read();
    const result = await Promise.race([pendingRead, timeout]);
    if (result === null) break;
    pendingRead = null;
    if (result.done) break;
    if (result.value) {
      totalBuffer += decoder.decode(result.value, { stream: true });
    }
  }

  let successCount = 0;
  const message = "X".repeat(messageSize);

  for (let i = 0; i < 50; i++) {
    const marker = "M" + i + "E";
    const data = marker + message.slice(marker.length);

    client.stdin!.write(data);
    client.stdin!.flush();

    let found = false;
    const start = performance.now();

    while (performance.now() - start < 200) {
      if (totalBuffer.includes(marker)) {
        found = true;
        break;
      }

      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 5));
      if (!pendingRead) pendingRead = reader.read();
      const result = await Promise.race([pendingRead, timeout]);

      if (result === null) continue;
      pendingRead = null;
      if (result.done) break;
      if (result.value) {
        totalBuffer += decoder.decode(result.value, { stream: true });
      }
    }

    if (found) {
      successCount++;
    } else {
      break;
    }
  }

  reader.releaseLock();
  client.kill(9);
  await client.exited;
  master.kill(9);
  await master.exited;

  try { unlinkSync(socketPath); } catch {}

  return successCount;
}

async function main() {
  console.log("Testing different message sizes...\n");

  const sizes = [16, 32, 48, 64, 80, 96, 128, 256, 512];

  for (const size of sizes) {
    const count = await testWithSize(size);
    const status = count >= 50 ? "✓" : "✗";
    console.log(status + " Size " + size + " bytes: " + count + "/50 iterations");
  }
}

main().catch(console.error);
