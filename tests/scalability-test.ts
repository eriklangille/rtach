/**
 * Scalability test - shows xev/kqueue advantage with many connections
 */

import { spawn, Subprocess } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), `rtach-scale-${id}.sock`);
}

async function waitForSocket(path: string): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < 5000) {
    try {
      const stat = statSync(path);
      if (stat.isSocket()) return true;
    } catch {}
    await Bun.sleep(20);
  }
  return false;
}

async function testWithNClients(n: number): Promise<{
  connectTimeMs: number;
  messagesPerSec: number;
  avgLatencyUs: number;
}> {
  const socketPath = uniqueSocketPath();

  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);

  // Connect all clients
  const connectStart = performance.now();
  const clients: Subprocess[] = [];
  const readers: ReadableStreamDefaultReader<Uint8Array>[] = [];

  for (let i = 0; i < n; i++) {
    const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    clients.push(client);
    readers.push(client.stdout!.getReader());
  }

  // Wait for all to be ready
  await Bun.sleep(50);
  const connectTimeMs = performance.now() - connectStart;

  // Drain initial data from all clients
  for (const reader of readers) {
    while (true) {
      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 5));
      const result = await Promise.race([reader.read(), timeout]);
      if (result === null) break;
      if (result.done) break;
    }
  }

  // Send messages from each client and measure round-trip
  const messagesPerClient = 50;
  const latencies: number[] = [];
  let totalMessages = 0;

  const testStart = performance.now();

  for (let msg = 0; msg < messagesPerClient; msg++) {
    // All clients send simultaneously
    const marker = `M${msg}E`;
    for (let i = 0; i < n; i++) {
      clients[i].stdin!.write(marker);
      clients[i].stdin!.flush();
    }

    // Wait for echoes
    const sendTime = performance.now();
    const received = new Set<number>();
    const buffers: string[] = new Array(n).fill("");
    const decoders = readers.map(() => new TextDecoder());

    while (received.size < n && performance.now() - sendTime < 500) {
      for (let i = 0; i < n; i++) {
        if (received.has(i)) continue;

        const timeout = new Promise<null>((r) => setTimeout(() => r(null), 1));
        const result = await Promise.race([readers[i].read(), timeout]);

        if (result === null) continue;
        if (result.done) continue;
        if (result.value) {
          buffers[i] += decoders[i].decode(result.value, { stream: true });
          if (buffers[i].includes(marker)) {
            received.add(i);
            latencies.push((performance.now() - sendTime) * 1000);
            totalMessages++;
          }
        }
      }
    }
  }

  const testDuration = performance.now() - testStart;

  // Cleanup
  for (const reader of readers) {
    reader.releaseLock();
  }
  for (const client of clients) {
    client.kill(9);
    await client.exited;
  }
  master.kill(9);
  await master.exited;
  try { unlinkSync(socketPath); } catch {}

  const avgLatency = latencies.length > 0
    ? latencies.reduce((a, b) => a + b, 0) / latencies.length
    : 0;

  return {
    connectTimeMs,
    messagesPerSec: (totalMessages / testDuration) * 1000,
    avgLatencyUs: avgLatency,
  };
}

async function main() {
  console.log("=".repeat(60));
  console.log("  rtach Scalability Test (xev/kqueue backend)");
  console.log("=".repeat(60));
  console.log("\n  Testing how performance scales with concurrent connections\n");
  console.log("  Clients | Connect Time | Msg/sec  | Avg Latency");
  console.log("  --------|--------------|----------|------------");

  const clientCounts = [1, 5, 10, 20, 30, 50];

  for (const n of clientCounts) {
    try {
      const result = await testWithNClients(n);
      console.log(
        `  ${String(n).padStart(7)} | ` +
        `${result.connectTimeMs.toFixed(0).padStart(9)}ms | ` +
        `${result.messagesPerSec.toFixed(0).padStart(8)} | ` +
        `${result.avgLatencyUs.toFixed(0).padStart(8)}µs`
      );
    } catch (e) {
      console.log(`  ${String(n).padStart(7)} | ERROR: ${e}`);
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log("  Key xev/kqueue advantages:");
  console.log("  - O(1) event notification vs O(n) for poll()");
  console.log("  - No FD array rebuilding each iteration");
  console.log("  - Kernel-level event filtering");
  console.log("  - Supports io_uring on Linux for even better perf");
  console.log("=".repeat(60) + "\n");
}

main().catch(console.error);
