#!/usr/bin/env bun
/**
 * Standalone benchmark runner for rtach
 * All waits are event-based (no sleep)
 *
 * Run with: bun run benchmark.ts
 */

import { spawn } from "bun";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupSocket,
  waitForSocket,
  startDetachedMaster,
  connectClient,
  connectAndWait,
  waitForOutput,
  writeToProc,
  killAndWait,
  getProcessMemory,
  formatBytes,
  formatDuration,
  calculateStats,
  type Stats,
} from "./helpers";

// ANSI colors
const COLORS = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  cyan: "\x1b[36m",
};

function header(text: string): void {
  console.log(`\n${COLORS.bold}${COLORS.blue}━━━ ${text} ━━━${COLORS.reset}\n`);
}

function metric(name: string, value: string): void {
  console.log(`  ${COLORS.cyan}${name}:${COLORS.reset} ${value}`);
}

function statsTable(stats: Stats): void {
  console.log(`  ┌─────────┬───────────────┐`);
  console.log(`  │ ${COLORS.dim}Metric${COLORS.reset}  │ ${COLORS.dim}Value${COLORS.reset}         │`);
  console.log(`  ├─────────┼───────────────┤`);
  console.log(`  │ Min     │ ${formatDuration(stats.min).padStart(11)} │`);
  console.log(`  │ Max     │ ${formatDuration(stats.max).padStart(11)} │`);
  console.log(`  │ Mean    │ ${formatDuration(stats.mean).padStart(11)} │`);
  console.log(`  │ Median  │ ${formatDuration(stats.median).padStart(11)} │`);
  console.log(`  │ StdDev  │ ${formatDuration(stats.stdDev).padStart(11)} │`);
  console.log(`  │ P95     │ ${formatDuration(stats.p95).padStart(11)} │`);
  console.log(`  │ P99     │ ${formatDuration(stats.p99).padStart(11)} │`);
  console.log(`  └─────────┴───────────────┘`);
}

async function benchmarkStartup(): Promise<void> {
  header("Startup Performance");

  const iterations = 20;
  const times: number[] = [];

  for (let i = 0; i < iterations; i++) {
    const socketPath = uniqueSocketPath();

    const start = performance.now();
    const proc = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    await waitForSocket(socketPath, 5000);
    const elapsed = performance.now() - start;
    times.push(elapsed);

    await killAndWait(proc, 9);
    cleanupSocket(socketPath);

    process.stdout.write(`\r  Progress: ${i + 1}/${iterations}`);
  }
  console.log();

  const stats = calculateStats(times);
  console.log(`\n  ${COLORS.green}Master Startup Time${COLORS.reset}`);
  statsTable(stats);
}

async function benchmarkConnect(): Promise<void> {
  header("Connection Performance");

  const socketPath = uniqueSocketPath();
  const master = await startDetachedMaster(socketPath, "/bin/cat");

  const iterations = 50;
  const times: number[] = [];

  for (let i = 0; i < iterations; i++) {
    const start = performance.now();
    const client = await connectAndWait(socketPath, { noDetachChar: true });
    const elapsed = performance.now() - start;
    times.push(elapsed);

    client.kill(9);
    await client.exited;

    process.stdout.write(`\r  Progress: ${i + 1}/${iterations}`);
  }
  console.log();

  await killAndWait(master, 9);
  cleanupSocket(socketPath);

  const stats = calculateStats(times);
  console.log(`\n  ${COLORS.green}Client Connect Time${COLORS.reset}`);
  statsTable(stats);
}

async function benchmarkThroughput(): Promise<void> {
  header("Throughput Benchmarks");

  const socketPath = uniqueSocketPath();
  const master = await startDetachedMaster(socketPath, "/bin/cat", 100 * 1024 * 1024);

  const sizes = [64, 1024, 4096, 16384];

  for (const size of sizes) {
    const client = await connectAndWait(socketPath, { noDetachChar: true });

    const iterations = size < 4096 ? 100 : 30;
    const times: number[] = [];

    for (let i = 0; i < iterations; i++) {
      const marker = `M${i}`;
      const message = marker + "X".repeat(size - marker.length - 1) + "\n";
      const start = performance.now();
      await writeToProc(client, message);
      await waitForOutput(client, marker, 2000);
      const elapsed = performance.now() - start;
      times.push(elapsed);
    }

    client.kill(9);
    await client.exited;

    const stats = calculateStats(times);
    const messagesPerSecond = 1000 / stats.mean;
    const bytesPerSecond = messagesPerSecond * size;

    console.log(`\n  ${COLORS.green}Message Size: ${formatBytes(size)}${COLORS.reset}`);
    metric("Throughput", `${formatBytes(bytesPerSecond)}/s`);
    metric("Messages/sec", messagesPerSecond.toFixed(0));
    metric("Mean latency", formatDuration(stats.mean));
    metric("P99 latency", formatDuration(stats.p99));
  }

  await killAndWait(master, 9);
  cleanupSocket(socketPath);
}

async function benchmarkBulkTransfer(): Promise<void> {
  header("Bulk Transfer");

  const sizes = [1, 10]; // MB

  for (const sizeMB of sizes) {
    const socketPath = uniqueSocketPath();
    const scrollbackSize = (sizeMB + 10) * 1024 * 1024;
    const master = await startDetachedMaster(socketPath, "/bin/cat", scrollbackSize);

    const client = await connectAndWait(socketPath, { noDetachChar: true });

    const chunkSize = 4096;
    const totalSize = sizeMB * 1024 * 1024;
    const chunks = totalSize / chunkSize;
    const chunk = "X".repeat(chunkSize);

    process.stdout.write(`  Transferring ${sizeMB}MB...`);

    const start = performance.now();
    for (let i = 0; i < chunks; i++) {
      await writeToProc(client, chunk);
      if (i % 64 === 0) {
        process.stdout.write(".");
      }
    }
    // Final marker to confirm all data processed
    const endMarker = `__END_${Date.now()}__`;
    await writeToProc(client, endMarker);
    await waitForOutput(client, endMarker, 30000);
    const elapsed = performance.now() - start;

    console.log(" done");

    client.kill(9);
    await client.exited;
    await killAndWait(master, 9);
    cleanupSocket(socketPath);

    const throughputMBps = totalSize / (elapsed / 1000) / (1024 * 1024);
    metric(`${sizeMB}MB Transfer`, `${throughputMBps.toFixed(2)} MB/s (${formatDuration(elapsed)})`);
  }
}

async function benchmarkMemory(): Promise<void> {
  header("Memory Usage");

  // Baseline
  const socketPath1 = uniqueSocketPath();
  const master1 = await startDetachedMaster(socketPath1, "/bin/cat", 1024 * 1024);

  const client1 = await connectAndWait(socketPath1, { noDetachChar: true });
  client1.kill(9);
  await client1.exited;

  const baseline = getProcessMemory(master1.pid);
  if (baseline) {
    metric("Baseline (1MB scrollback)", formatBytes(baseline));
  }

  await killAndWait(master1, 9);
  cleanupSocket(socketPath1);

  // With data
  const scrollbackSizes = [1, 4, 16]; // MB

  for (const sizeMB of scrollbackSizes) {
    const socketPath = uniqueSocketPath();
    const scrollbackSize = sizeMB * 1024 * 1024;
    const master = await startDetachedMaster(socketPath, "/bin/cat", scrollbackSize);

    // Fill scrollback
    const client = await connectAndWait(socketPath, { noDetachChar: true });

    const chunk = "X".repeat(4096);
    const chunks = (sizeMB * 1024 * 1024) / 4096;
    for (let i = 0; i < chunks; i++) {
      await writeToProc(client, chunk);
    }
    // Confirm fill complete
    const endMarker = `__FILL_${sizeMB}MB__`;
    await writeToProc(client, endMarker);
    await waitForOutput(client, endMarker, 30000);

    const memory = getProcessMemory(master.pid);
    if (memory) {
      const efficiency = (scrollbackSize / memory) * 100;
      metric(
        `${sizeMB}MB scrollback filled`,
        `${formatBytes(memory)} (${efficiency.toFixed(1)}% efficient)`
      );
    }

    client.kill(9);
    await client.exited;
    await killAndWait(master, 9);
    cleanupSocket(socketPath);
  }

  // Per-client overhead
  console.log();
  const socketPath2 = uniqueSocketPath();
  const master2 = await startDetachedMaster(socketPath2, "/bin/cat");

  const baseClient = await connectAndWait(socketPath2, { noDetachChar: true });
  const beforeClients = getProcessMemory(master2.pid);

  const clients: ReturnType<typeof spawn>[] = [baseClient];
  for (let i = 0; i < 20; i++) {
    const client = await connectAndWait(socketPath2, { noDetachChar: true });
    clients.push(client);
  }

  const afterClients = getProcessMemory(master2.pid);

  for (const client of clients) {
    client.kill(9);
    await client.exited;
  }
  await killAndWait(master2, 9);
  cleanupSocket(socketPath2);

  if (beforeClients && afterClients) {
    const perClient = (afterClients - beforeClients) / 20;
    metric("Per-client overhead (20 clients)", formatBytes(perClient));
  }
}

async function benchmarkScrollbackReplay(): Promise<void> {
  header("Scrollback Replay");

  const sizes = [256, 1024]; // KB

  for (const sizeKB of sizes) {
    const socketPath = uniqueSocketPath();
    const scrollbackSize = sizeKB * 1024;
    const master = await startDetachedMaster(socketPath, "/bin/cat", scrollbackSize);

    // Fill scrollback
    const client1 = await connectAndWait(socketPath, { noDetachChar: true });

    const chunk = "X".repeat(4096);
    const chunks = scrollbackSize / 4096;
    for (let i = 0; i < chunks; i++) {
      await writeToProc(client1, chunk);
    }
    // Add marker at end
    const fillMarker = `__FILLED_${sizeKB}KB__`;
    await writeToProc(client1, fillMarker);
    await waitForOutput(client1, fillMarker, 10000);

    client1.kill(9);
    await client1.exited;

    // Measure replay time
    const iterations = 5;
    const times: number[] = [];

    for (let i = 0; i < iterations; i++) {
      const start = performance.now();
      const client = connectClient(socketPath, { noDetachChar: true });

      // Wait for scrollback replay (marker should appear)
      await waitForOutput(client, fillMarker, 10000);
      const elapsed = performance.now() - start;
      times.push(elapsed);

      client.kill(9);
      await client.exited;
    }

    await killAndWait(master, 9);
    cleanupSocket(socketPath);

    const stats = calculateStats(times);
    const throughput = (scrollbackSize / stats.mean) * 1000;

    console.log(`\n  ${COLORS.green}Scrollback: ${sizeKB}KB${COLORS.reset}`);
    metric("Replay time", formatDuration(stats.mean));
    metric("Throughput", `${formatBytes(throughput)}/s`);
  }
}

async function benchmarkConcurrency(): Promise<void> {
  header("Concurrency");

  const clientCounts = [1, 5, 10];

  for (const numClients of clientCounts) {
    const socketPath = uniqueSocketPath();
    const master = await startDetachedMaster(socketPath, "/bin/cat", 50 * 1024 * 1024);

    const clients: Awaited<ReturnType<typeof connectAndWait>>[] = [];
    for (let i = 0; i < numClients; i++) {
      const client = await connectAndWait(socketPath, { noDetachChar: true });
      clients.push(client);
    }

    const message = "X".repeat(1024);
    const iterations = 100;

    const start = performance.now();
    await Promise.all(
      clients.map(async (client, idx) => {
        for (let i = 0; i < iterations; i++) {
          await writeToProc(client, message);
        }
        // Confirm all writes complete
        const marker = `__CLIENT${idx}_DONE__`;
        await writeToProc(client, marker);
        await waitForOutput(client, marker, 10000);
      })
    );
    const elapsed = performance.now() - start;

    for (const client of clients) {
      client.kill(9);
      await client.exited;
    }
    await killAndWait(master, 9);
    cleanupSocket(socketPath);

    const totalMessages = numClients * iterations;
    const totalBytes = totalMessages * 1024;
    const messagesPerSecond = (totalMessages / elapsed) * 1000;
    const throughput = (totalBytes / elapsed) * 1000;

    metric(
      `${numClients} clients × ${iterations} msgs`,
      `${messagesPerSecond.toFixed(0)} msg/s, ${formatBytes(throughput)}/s`
    );
  }
}

async function main(): Promise<void> {
  console.log(`\n${COLORS.bold}${COLORS.yellow}╔═══════════════════════════════════════╗${COLORS.reset}`);
  console.log(`${COLORS.bold}${COLORS.yellow}║     rtach Performance Benchmarks      ║${COLORS.reset}`);
  console.log(`${COLORS.bold}${COLORS.yellow}╚═══════════════════════════════════════╝${COLORS.reset}`);

  console.log(`\n${COLORS.dim}Binary: ${RTACH_BIN}${COLORS.reset}`);
  console.log(`${COLORS.dim}Platform: ${process.platform} ${process.arch}${COLORS.reset}`);
  console.log(`${COLORS.dim}Date: ${new Date().toISOString()}${COLORS.reset}`);

  try {
    await benchmarkStartup();
    await benchmarkConnect();
    await benchmarkThroughput();
    await benchmarkBulkTransfer();
    await benchmarkMemory();
    await benchmarkScrollbackReplay();
    await benchmarkConcurrency();

    console.log(`\n${COLORS.bold}${COLORS.green}✓ All benchmarks completed${COLORS.reset}\n`);
  } catch (error) {
    console.error(`\n${COLORS.bold}Benchmark failed:${COLORS.reset}`, error);
    process.exit(1);
  }
}

main();
