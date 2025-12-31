import { describe, test, expect } from "bun:test";
import { spawn, spawnSync } from "bun";
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

// Check if native dtach is available
const DTACH_BIN = (() => {
  const result = spawnSync(["which", "dtach"]);
  if (result.exitCode === 0) {
    return result.stdout.toString().trim();
  }
  return null;
})();

const HAS_DTACH = DTACH_BIN !== null;

function printStats(name: string, stats: Stats): void {
  console.log(`\n📊 ${name}`);
  console.log(`   Min:    ${formatDuration(stats.min)}`);
  console.log(`   Max:    ${formatDuration(stats.max)}`);
  console.log(`   Mean:   ${formatDuration(stats.mean)}`);
  console.log(`   Median: ${formatDuration(stats.median)}`);
  console.log(`   StdDev: ${formatDuration(stats.stdDev)}`);
  console.log(`   P95:    ${formatDuration(stats.p95)}`);
  console.log(`   P99:    ${formatDuration(stats.p99)}`);
}

describe("rtach benchmarks", () => {
  describe("startup performance", () => {
    test("master startup time", async () => {
      const times: number[] = [];

      for (let i = 0; i < 20; i++) {
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
      }

      const stats = calculateStats(times);
      printStats("Master Startup Time", stats);

      expect(stats.median).toBeLessThan(500);
      expect(stats.p99).toBeLessThan(1000);
    });

    test("client connect time", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat");

      const times: number[] = [];
      for (let i = 0; i < 20; i++) {
        const start = performance.now();
        const client = await connectAndWait(socketPath, { noDetachChar: true });
        const elapsed = performance.now() - start;
        times.push(elapsed);

        client.kill(9);
        await client.exited;
      }

      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      const stats = calculateStats(times);
      printStats("Client Connect Time", stats);

      expect(stats.median).toBeLessThan(200);
    });
  });

  describe("latency", () => {
    test("round-trip latency (64 bytes)", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat");
      const client = await connectAndWait(socketPath, { noDetachChar: true });

      const times: number[] = [];
      // Use 63 bytes + newline to flush PTY line buffer (canonical mode has 1024-byte limit)
      const message = "X".repeat(62) + "\n";

      for (let i = 0; i < 50; i++) {
        const marker = `L${i}`;
        const start = performance.now();
        await writeToProc(client, marker + message.slice(marker.length));
        await waitForOutput(client, marker, 1000);
        const elapsed = performance.now() - start;
        times.push(elapsed);
      }

      client.kill(9);
      await client.exited;
      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      const stats = calculateStats(times);
      printStats("Round-trip Latency (64 bytes)", stats);

      expect(stats.median).toBeLessThan(20);
    });
  });

  describe("throughput", () => {
    test("small message throughput (64 bytes)", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat", 10 * 1024 * 1024);
      const client = await connectAndWait(socketPath, { noDetachChar: true });

      const times: number[] = [];
      // Use 63 bytes + newline to flush PTY line buffer (canonical mode has 1024-byte limit)
      const message = "X".repeat(62) + "\n";

      for (let i = 0; i < 100; i++) {
        const marker = `M${i}`;
        const start = performance.now();
        await writeToProc(client, marker + message.slice(marker.length));
        await waitForOutput(client, marker, 1000);
        const elapsed = performance.now() - start;
        times.push(elapsed);
      }

      client.kill(9);
      await client.exited;
      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      const stats = calculateStats(times);
      const messagesPerSecond = 1000 / stats.mean;

      console.log(`\n📊 Small Message Throughput (64 bytes)`);
      console.log(`   Messages/sec: ${messagesPerSecond.toFixed(0)}`);
      console.log(`   Throughput:   ${formatBytes(messagesPerSecond * 64)}/s`);
      printStats("Per-message latency", stats);

      expect(stats.median).toBeLessThan(50);
    });
  });

  describe("memory usage", () => {
    test("master memory baseline", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat", 1024 * 1024);

      // Connect briefly to ensure it's fully initialized
      const client = await connectAndWait(socketPath, { noDetachChar: true });
      client.kill(9);
      await client.exited;

      const memory = getProcessMemory(master.pid);

      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      console.log(`\n📊 Master Memory Baseline`);
      if (memory !== null) {
        console.log(`   RSS: ${formatBytes(memory)}`);
        expect(memory).toBeLessThan(10 * 1024 * 1024);
      } else {
        console.log(`   RSS: (Memory measurement not available on this platform)`);
        // Skip assertion when measurement not available
      }
    });

    test("memory with multiple clients", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat");

      // Baseline with one client
      const baseClient = await connectAndWait(socketPath, { noDetachChar: true });
      const baselineMemory = getProcessMemory(master.pid);

      // Connect 10 more clients
      const clients = [baseClient];
      for (let i = 0; i < 10; i++) {
        const c = await connectAndWait(socketPath, { noDetachChar: true });
        clients.push(c);
      }

      const withClientsMemory = getProcessMemory(master.pid);

      for (const client of clients) {
        client.kill(9);
        await client.exited;
      }
      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      console.log(`\n📊 Memory with 10 Additional Clients`);
      if (baselineMemory !== null && withClientsMemory !== null) {
        console.log(`   Baseline (1 client):   ${formatBytes(baselineMemory)}`);
        console.log(`   With 11 clients:       ${formatBytes(withClientsMemory)}`);
        console.log(`   Per additional client: ${formatBytes((withClientsMemory - baselineMemory) / 10)}`);

        const perClient = (withClientsMemory - baselineMemory) / 10;
        expect(perClient).toBeLessThan(100 * 1024);
      } else {
        console.log(`   (Memory measurement not available on this platform)`);
        // Skip assertion when measurement not available
      }
    });
  });

  describe("scalability", () => {
    test("rapid connect/disconnect (20 cycles)", async () => {
      const socketPath = uniqueSocketPath();
      const master = await startDetachedMaster(socketPath, "/bin/cat");

      const times: number[] = [];
      for (let i = 0; i < 20; i++) {
        const start = performance.now();
        const client = await connectAndWait(socketPath, { noDetachChar: true });
        client.kill(9);
        await client.exited;
        const elapsed = performance.now() - start;
        times.push(elapsed);
      }

      await killAndWait(master, 9);
      cleanupSocket(socketPath);

      const stats = calculateStats(times);
      console.log(`\n📊 Rapid Connect/Disconnect (20 cycles)`);
      console.log(`   Total time: ${formatDuration(times.reduce((a, b) => a + b, 0))}`);
      printStats("Per-cycle time", stats);

      expect(stats.mean).toBeLessThan(500);
    });
  });
});

describe("rtach vs dtach comparison", () => {
  test("startup time comparison", async () => {
    const iterations = 10;

    // Measure rtach startup
    const rtachTimes: number[] = [];
    for (let i = 0; i < iterations; i++) {
      const socketPath = uniqueSocketPath();
      const start = performance.now();
      const proc = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
        stdout: "pipe",
        stderr: "pipe",
      });
      await waitForSocket(socketPath, 5000);
      rtachTimes.push(performance.now() - start);
      await killAndWait(proc, 9);
      cleanupSocket(socketPath);
    }
    const rtachStats = calculateStats(rtachTimes);

    // Measure dtach startup if available
    let dtachStats: Stats | null = null;
    if (HAS_DTACH && DTACH_BIN) {
      const dtachTimes: number[] = [];
      for (let i = 0; i < iterations; i++) {
        const socketPath = uniqueSocketPath();
        const start = performance.now();
        const proc = spawn([DTACH_BIN, "-n", socketPath, "/bin/cat"], {
          stdout: "pipe",
          stderr: "pipe",
        });
        await waitForSocket(socketPath, 5000);
        dtachTimes.push(performance.now() - start);
        await killAndWait(proc, 9);
        cleanupSocket(socketPath);
      }
      dtachStats = calculateStats(dtachTimes);
    }

    console.log(`\n📊 Startup Time Comparison`);
    console.log(`   rtach median: ${formatDuration(rtachStats.median)}`);
    if (dtachStats) {
      console.log(`   dtach median: ${formatDuration(dtachStats.median)}`);
      const ratio = dtachStats.median / rtachStats.median;
      const faster = ratio > 1 ? "rtach" : "dtach";
      const speedup = ratio > 1 ? ratio : 1 / ratio;
      console.log(`   ${faster} is ${speedup.toFixed(2)}x faster`);
    } else {
      console.log(`   dtach: not installed`);
    }

    expect(rtachStats.median).toBeLessThan(500);
  });
});
