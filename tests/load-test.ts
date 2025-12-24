/**
 * Load test comparing rtach vs dtach under various conditions
 */

import { spawn, Subprocess } from "bun";
import { join } from "path";
import { tmpdir } from "os";
import { statSync, unlinkSync } from "fs";

const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

function uniqueSocketPath(prefix: string): string {
  const id = Math.random().toString(36).substring(2, 10);
  return join(tmpdir(), `${prefix}-${id}.sock`);
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

function formatNumber(n: number): string {
  if (n >= 1000000) return (n / 1000000).toFixed(2) + "M";
  if (n >= 1000) return (n / 1000).toFixed(2) + "K";
  return n.toString();
}

interface LoadTestResult {
  name: string;
  totalMessages: number;
  totalBytes: number;
  durationMs: number;
  messagesPerSec: number;
  throughputMBps: number;
  avgLatencyUs: number;
  p99LatencyUs: number;
}

async function runRtachLoadTest(
  numClients: number,
  messagesPerClient: number,
  messageSize: number
): Promise<LoadTestResult> {
  const socketPath = uniqueSocketPath("rtach-load");

  // Start master
  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);
  await Bun.sleep(100);

  // Create clients
  const clients: Subprocess[] = [];
  const readers: ReadableStreamDefaultReader<Uint8Array>[] = [];

  for (let i = 0; i < numClients; i++) {
    const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    clients.push(client);
    readers.push(client.stdout!.getReader());
  }

  // Wait for all clients to connect
  await Bun.sleep(100);

  const message = "X".repeat(messageSize);
  const latencies: number[] = [];
  let totalBytesWritten = 0;
  let totalBytesRead = 0;
  let totalMessages = 0;

  const startTime = performance.now();

  // Each client sends messages and measures round-trip
  const clientPromises = clients.map(async (client, clientIdx) => {
    const reader = readers[clientIdx];
    const decoder = new TextDecoder();
    let buffer = "";
    let pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;

    // Drain initial data
    while (true) {
      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 10));
      if (!pendingRead) pendingRead = reader.read();
      const result = await Promise.race([pendingRead, timeout]);
      if (result === null) break;
      pendingRead = null;
      if (result.done) break;
      if (result.value) buffer += decoder.decode(result.value, { stream: true });
    }

    for (let i = 0; i < messagesPerClient; i++) {
      const marker = `C${clientIdx}M${i}E`;
      const data = marker + message.slice(marker.length);

      const sendStart = performance.now();
      client.stdin!.write(data);
      client.stdin!.flush();
      totalBytesWritten += data.length;

      // Wait for echo
      const timeout = 1000;
      const waitStart = Date.now();
      while (Date.now() - waitStart < timeout) {
        if (buffer.includes(marker)) {
          const latency = (performance.now() - sendStart) * 1000; // to microseconds
          latencies.push(latency);
          totalMessages++;
          break;
        }

        const timeoutPromise = new Promise<null>((r) => setTimeout(() => r(null), 5));
        if (!pendingRead) pendingRead = reader.read();
        const result = await Promise.race([pendingRead, timeoutPromise]);

        if (result === null) continue;
        pendingRead = null;
        if (result.done) break;
        if (result.value) {
          const chunk = decoder.decode(result.value, { stream: true });
          buffer += chunk;
          totalBytesRead += result.value.length;
        }
      }
    }

    reader.releaseLock();
  });

  await Promise.all(clientPromises);

  const endTime = performance.now();
  const durationMs = endTime - startTime;

  // Cleanup
  for (const client of clients) {
    client.kill(9);
    await client.exited;
  }
  master.kill(9);
  await master.exited;
  try { unlinkSync(socketPath); } catch {}

  // Calculate stats
  latencies.sort((a, b) => a - b);
  const avgLatency = latencies.length > 0 ? latencies.reduce((a, b) => a + b, 0) / latencies.length : 0;
  const p99Idx = Math.floor(latencies.length * 0.99);
  const p99Latency = latencies.length > 0 ? latencies[p99Idx] : 0;

  return {
    name: "rtach",
    totalMessages,
    totalBytes: totalBytesWritten,
    durationMs,
    messagesPerSec: (totalMessages / durationMs) * 1000,
    throughputMBps: (totalBytesWritten / durationMs) * 1000 / (1024 * 1024),
    avgLatencyUs: avgLatency,
    p99LatencyUs: p99Latency,
  };
}

async function runConcurrentConnectionTest(maxClients: number): Promise<void> {
  console.log(`\n📊 Concurrent Connection Test (up to ${maxClients} clients)\n`);

  const socketPath = uniqueSocketPath("rtach-conn");

  const master = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
    stdout: "pipe",
    stderr: "pipe",
  });

  await waitForSocket(socketPath);
  await Bun.sleep(100);

  const clients: Subprocess[] = [];
  const connectionTimes: number[] = [];

  for (let i = 0; i < maxClients; i++) {
    const start = performance.now();
    const client = spawn([RTACH_BIN, "-a", socketPath, "-E"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });
    clients.push(client);

    // Wait for client to connect (read initial data)
    const reader = client.stdout!.getReader();
    const timeout = new Promise<null>((r) => setTimeout(() => r(null), 100));
    await Promise.race([reader.read(), timeout]);
    reader.releaseLock();

    const elapsed = performance.now() - start;
    connectionTimes.push(elapsed);

    if ((i + 1) % 10 === 0 || i === maxClients - 1) {
      const avgTime = connectionTimes.slice(-10).reduce((a, b) => a + b, 0) / Math.min(10, connectionTimes.length);
      console.log(`  ${i + 1} clients connected (last 10 avg: ${avgTime.toFixed(2)}ms)`);
    }
  }

  // Test that all clients can still send/receive
  console.log("\n  Testing message delivery with all clients connected...");

  let successCount = 0;
  const testPromises = clients.slice(0, 10).map(async (client, idx) => {
    const reader = client.stdout!.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    // Drain any pending data
    while (true) {
      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 10));
      const result = await Promise.race([reader.read(), timeout]);
      if (result === null) break;
      if (result.done) break;
      if (result.value) buffer += decoder.decode(result.value, { stream: true });
    }

    const marker = `TEST${idx}`;
    client.stdin!.write(marker);
    client.stdin!.flush();

    const start = Date.now();
    while (Date.now() - start < 500) {
      if (buffer.includes(marker)) {
        successCount++;
        break;
      }
      const timeout = new Promise<null>((r) => setTimeout(() => r(null), 10));
      const result = await Promise.race([reader.read(), timeout]);
      if (result === null) continue;
      if (result.done) break;
      if (result.value) buffer += decoder.decode(result.value, { stream: true });
    }

    reader.releaseLock();
  });

  await Promise.all(testPromises);
  console.log(`  Message delivery: ${successCount}/10 successful\n`);

  // Cleanup
  for (const client of clients) {
    client.kill(9);
    await client.exited;
  }
  master.kill(9);
  await master.exited;
  try { unlinkSync(socketPath); } catch {}

  const totalTime = connectionTimes.reduce((a, b) => a + b, 0);
  const avgTime = totalTime / connectionTimes.length;
  console.log(`  Total connection time: ${totalTime.toFixed(0)}ms`);
  console.log(`  Average per connection: ${avgTime.toFixed(2)}ms`);
}

async function main() {
  console.log("=".repeat(60));
  console.log("  rtach Load Test (xev/kqueue backend)");
  console.log("=".repeat(60));

  // Test 1: Single client, many messages
  console.log("\n📊 Test 1: Single Client Throughput\n");
  const single = await runRtachLoadTest(1, 1000, 64);
  console.log(`  Messages:     ${formatNumber(single.totalMessages)}`);
  console.log(`  Duration:     ${single.durationMs.toFixed(0)}ms`);
  console.log(`  Throughput:   ${formatNumber(single.messagesPerSec)} msg/sec`);
  console.log(`  Bandwidth:    ${single.throughputMBps.toFixed(2)} MB/s`);
  console.log(`  Avg latency:  ${single.avgLatencyUs.toFixed(0)}µs`);
  console.log(`  P99 latency:  ${single.p99LatencyUs.toFixed(0)}µs`);

  // Test 2: Multiple clients, concurrent
  console.log("\n📊 Test 2: 10 Concurrent Clients\n");
  const multi = await runRtachLoadTest(10, 100, 64);
  console.log(`  Messages:     ${formatNumber(multi.totalMessages)}`);
  console.log(`  Duration:     ${multi.durationMs.toFixed(0)}ms`);
  console.log(`  Throughput:   ${formatNumber(multi.messagesPerSec)} msg/sec`);
  console.log(`  Bandwidth:    ${multi.throughputMBps.toFixed(2)} MB/s`);
  console.log(`  Avg latency:  ${multi.avgLatencyUs.toFixed(0)}µs`);
  console.log(`  P99 latency:  ${multi.p99LatencyUs.toFixed(0)}µs`);

  // Test 3: Large messages
  console.log("\n📊 Test 3: Large Messages (4KB)\n");
  const large = await runRtachLoadTest(1, 500, 4096);
  console.log(`  Messages:     ${formatNumber(large.totalMessages)}`);
  console.log(`  Duration:     ${large.durationMs.toFixed(0)}ms`);
  console.log(`  Throughput:   ${formatNumber(large.messagesPerSec)} msg/sec`);
  console.log(`  Bandwidth:    ${large.throughputMBps.toFixed(2)} MB/s`);
  console.log(`  Avg latency:  ${large.avgLatencyUs.toFixed(0)}µs`);
  console.log(`  P99 latency:  ${large.p99LatencyUs.toFixed(0)}µs`);

  // Test 4: Many concurrent connections
  await runConcurrentConnectionTest(50);

  // Test 5: Sustained load
  console.log("\n📊 Test 5: Sustained Load (5 clients x 500 msgs)\n");
  const sustained = await runRtachLoadTest(5, 500, 128);
  console.log(`  Messages:     ${formatNumber(sustained.totalMessages)}`);
  console.log(`  Duration:     ${sustained.durationMs.toFixed(0)}ms`);
  console.log(`  Throughput:   ${formatNumber(sustained.messagesPerSec)} msg/sec`);
  console.log(`  Bandwidth:    ${sustained.throughputMBps.toFixed(2)} MB/s`);
  console.log(`  Avg latency:  ${sustained.avgLatencyUs.toFixed(0)}µs`);
  console.log(`  P99 latency:  ${sustained.p99LatencyUs.toFixed(0)}µs`);

  console.log("\n" + "=".repeat(60));
  console.log("  Load Test Complete");
  console.log("=".repeat(60) + "\n");
}

main().catch(console.error);
