/**
 * Debug the 1KB limit issue
 */

import { spawn } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), "rtach-1kb-" + id + ".sock");
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

  console.log("Starting master with verbose stderr...");
  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  // Capture master stderr
  const masterStderrReader = master.stderr!.getReader();
  const masterStderrDecoder = new TextDecoder();
  let masterStderr = "";

  (async () => {
    while (true) {
      try {
        const { done, value } = await masterStderrReader.read();
        if (done) break;
        if (value) {
          masterStderr += masterStderrDecoder.decode(value, { stream: true });
        }
      } catch { break; }
    }
  })();

  await waitForSocket(socketPath);
  console.log("Master ready");

  const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  // Capture client stderr
  const clientStderrReader = client.stderr!.getReader();
  const clientStderrDecoder = new TextDecoder();
  let clientStderr = "";

  (async () => {
    while (true) {
      try {
        const { done, value } = await clientStderrReader.read();
        if (done) break;
        if (value) {
          clientStderr += clientStderrDecoder.decode(value, { stream: true });
        }
      } catch { break; }
    }
  })();

  const reader = client.stdout!.getReader();
  const decoder = new TextDecoder();
  let totalBuffer = "";
  let pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;
  let totalBytesWritten = 0;
  let totalBytesRead = 0;

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
      totalBytesRead += result.value.length;
    }
  }
  console.log("Initial: " + totalBytesRead + " bytes read\n");

  const messageSize = 64;
  const message = "X".repeat(messageSize);

  for (let i = 0; i < 25; i++) {
    const marker = "M" + i + "E";
    const data = marker + message.slice(marker.length);

    client.stdin!.write(data);
    client.stdin!.flush();
    totalBytesWritten += data.length;

    let found = false;
    const start = performance.now();

    while (performance.now() - start < 500) {
      if (totalBuffer.includes(marker)) {
        found = true;
        break;
      }

      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 5));
      if (!pendingRead) pendingRead = reader.read();
      const result = await Promise.race([pendingRead, timeout]);

      if (result === null) continue;
      pendingRead = null;
      if (result.done) {
        console.log("  STDOUT STREAM ENDED at iteration " + i);
        break;
      }
      if (result.value) {
        totalBuffer += decoder.decode(result.value, { stream: true });
        totalBytesRead += result.value.length;
      }
    }

    if (found) {
      console.log("✓ " + i + ": written=" + totalBytesWritten + ", read=" + totalBytesRead);
    } else {
      console.log("✗ " + i + ": TIMEOUT after writing " + totalBytesWritten + " bytes, read " + totalBytesRead + " bytes");
      console.log("\nWaiting 1 second for any more data...");
      await Bun.sleep(1000);

      // Try to read any remaining data
      while (true) {
        const timeout = new Promise<null>((r) => setTimeout(() => r(null), 100));
        if (!pendingRead) pendingRead = reader.read();
        const result = await Promise.race([pendingRead, timeout]);
        if (result === null) break;
        pendingRead = null;
        if (result.done) {
          console.log("Stream ended");
          break;
        }
        if (result.value) {
          console.log("Late data: +" + result.value.length + " bytes");
          totalBuffer += decoder.decode(result.value, { stream: true });
          totalBytesRead += result.value.length;
        }
      }

      console.log("\nFinal state:");
      console.log("  Written: " + totalBytesWritten + " bytes");
      console.log("  Read:    " + totalBytesRead + " bytes");
      console.log("  Buffer length: " + totalBuffer.length);
      console.log("  Client alive: " + (client.exitCode === null));
      console.log("  Master alive: " + (master.exitCode === null));
      console.log("\nLooking for marker 'M16E' in buffer...");
      const idx = totalBuffer.indexOf("M16E");
      console.log("  indexOf result: " + idx);
      console.log("\nLast 200 chars of buffer:");
      console.log(JSON.stringify(totalBuffer.slice(-200)));
      console.log("\nMaster stderr:\n" + masterStderr);
      console.log("\nClient stderr:\n" + clientStderr);
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
