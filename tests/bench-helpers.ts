import { spawn, spawnSync, type Subprocess } from "bun";
import { existsSync } from "fs";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupSocket,
  waitForSocket,
  killAndWait,
  formatBytes,
  formatDuration,
  calculateStats,
  type Stats,
} from "./helpers";

// Check if native dtach is available
export const DTACH_BIN = (() => {
  const result = spawnSync(["which", "dtach"]);
  if (result.exitCode === 0) {
    return result.stdout.toString().trim();
  }
  return null;
})();

export const HAS_DTACH = DTACH_BIN !== null;

/**
 * A benchmark client that properly manages reader state.
 * Uses a persistent reader to avoid data loss between reads.
 */
export class BenchmarkClient {
  private proc: Subprocess;
  private reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private buffer: string = "";
  private decoder = new TextDecoder();
  private pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null = null;

  constructor(proc: Subprocess) {
    this.proc = proc;
    if (proc.stdout) {
      this.reader = proc.stdout.getReader();
    }
  }

  async write(data: string): Promise<void> {
    if (!this.proc.stdin) {
      throw new Error("No stdin available");
    }
    this.proc.stdin.write(data);
    this.proc.stdin.flush();
  }

  async waitFor(pattern: string | RegExp, timeoutMs: number = 5000): Promise<string> {
    if (!this.reader) {
      throw new Error("No stdout reader available");
    }

    const startTime = Date.now();

    while (Date.now() - startTime < timeoutMs) {
      // Check if pattern already in buffer
      const match =
        typeof pattern === "string"
          ? this.buffer.includes(pattern)
          : pattern.test(this.buffer);

      if (match) {
        return this.buffer;
      }

      // Read more data with timeout
      const remainingTime = timeoutMs - (Date.now() - startTime);
      const timeoutPromise = new Promise<null>((resolve) =>
        setTimeout(() => resolve(null), Math.min(remainingTime, 50))
      );

      // Start a read if we don't have one pending
      if (!this.pendingRead) {
        this.pendingRead = this.reader.read();
      }

      const result = await Promise.race([this.pendingRead, timeoutPromise]);

      if (result === null) {
        // Timeout - continue loop to check time
        continue;
      }

      // Got data
      this.pendingRead = null;

      if (result.done) {
        throw new Error("Stream ended unexpectedly");
      }

      if (result.value) {
        this.buffer += this.decoder.decode(result.value, { stream: true });
      }
    }

    throw new Error(`Timeout waiting for: ${pattern}`);
  }

  async writeAndWait(data: string, marker: string, timeoutMs: number = 1000): Promise<number> {
    const start = performance.now();
    await this.write(data);
    await this.waitFor(marker, timeoutMs);
    return performance.now() - start;
  }

  async close(): Promise<void> {
    if (this.reader) {
      try {
        this.reader.releaseLock();
      } catch {
        // Ignore
      }
    }
    this.proc.kill(9);
    await this.proc.exited;
  }

  get pid(): number {
    return this.proc.pid;
  }
}

/**
 * Session manager for benchmarks - handles master + client lifecycle
 */
export class BenchmarkSession {
  socketPath: string;
  master: Subprocess | null = null;
  tool: "rtach" | "dtach";

  constructor(tool: "rtach" | "dtach" = "rtach") {
    this.socketPath = uniqueSocketPath();
    this.tool = tool;
  }

  async start(command: string = "/bin/cat", scrollbackSize?: number): Promise<void> {
    if (this.tool === "rtach") {
      const args = ["-n", this.socketPath];
      if (scrollbackSize) {
        args.push("-s", scrollbackSize.toString());
      }
      args.push(command);

      this.master = spawn([RTACH_BIN, ...args], {
        stdout: "pipe",
        stderr: "pipe",
      });
    } else if (this.tool === "dtach" && DTACH_BIN) {
      // dtach -n socket command
      this.master = spawn([DTACH_BIN, "-n", this.socketPath, command], {
        stdout: "pipe",
        stderr: "pipe",
      });
    } else {
      throw new Error("dtach not available");
    }

    const ready = await waitForSocket(this.socketPath);
    if (!ready) {
      throw new Error(`Failed to create session at ${this.socketPath}`);
    }
  }

  connect(): BenchmarkClient {
    let proc: Subprocess;

    if (this.tool === "rtach") {
      proc = spawn([RTACH_BIN, "-a", this.socketPath, "-E"], {
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      });
    } else if (this.tool === "dtach" && DTACH_BIN) {
      proc = spawn([DTACH_BIN, "-a", this.socketPath, "-E"], {
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      });
    } else {
      throw new Error("dtach not available");
    }

    return new BenchmarkClient(proc);
  }

  async stop(): Promise<void> {
    if (this.master) {
      await killAndWait(this.master, 9);
      this.master = null;
    }
    cleanupSocket(this.socketPath);
  }

  get masterPid(): number {
    return this.master?.pid ?? 0;
  }
}

/**
 * Run a latency benchmark
 */
export async function measureLatency(
  session: BenchmarkSession,
  iterations: number,
  messageSize: number = 64
): Promise<Stats> {
  const client = session.connect();
  const times: number[] = [];
  const message = "X".repeat(messageSize);

  // Wait for connection to be ready by sending a probe
  await client.writeAndWait("__READY__", "__READY__", 5000);

  for (let i = 0; i < iterations; i++) {
    const marker = `M${i}`;
    const fullMessage = marker + message.slice(marker.length);
    const elapsed = await client.writeAndWait(fullMessage, marker);
    times.push(elapsed);
  }

  await client.close();
  return calculateStats(times);
}

/**
 * Run a throughput benchmark with interleaved reads
 */
export async function measureThroughput(
  session: BenchmarkSession,
  iterations: number,
  chunkSize: number = 512
): Promise<{ stats: Stats; totalBytes: number; throughputMBps: number }> {
  const client = session.connect();
  const times: number[] = [];
  const chunk = "X".repeat(chunkSize);

  // Wait for connection to be ready by sending a probe
  await client.writeAndWait("__READY__", "__READY__", 5000);

  const start = performance.now();
  for (let i = 0; i < iterations; i++) {
    const marker = `T${i}`;
    const fullChunk = marker + chunk.slice(marker.length);
    const elapsed = await client.writeAndWait(fullChunk, marker);
    times.push(elapsed);
  }
  const totalTime = performance.now() - start;

  await client.close();

  const totalBytes = iterations * chunkSize;
  const throughputMBps = totalBytes / (totalTime / 1000) / (1024 * 1024);

  return {
    stats: calculateStats(times),
    totalBytes,
    throughputMBps,
  };
}

/**
 * Print benchmark results
 */
export function printStats(name: string, stats: Stats): void {
  console.log(`\n📊 ${name}`);
  console.log(`   Min:    ${formatDuration(stats.min)}`);
  console.log(`   Max:    ${formatDuration(stats.max)}`);
  console.log(`   Mean:   ${formatDuration(stats.mean)}`);
  console.log(`   Median: ${formatDuration(stats.median)}`);
  console.log(`   StdDev: ${formatDuration(stats.stdDev)}`);
  console.log(`   P95:    ${formatDuration(stats.p95)}`);
  console.log(`   P99:    ${formatDuration(stats.p99)}`);
}

/**
 * Print comparison between rtach and dtach
 */
export function printComparison(
  metric: string,
  rtachStats: Stats,
  dtachStats: Stats | null
): void {
  console.log(`\n📊 ${metric}`);
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
}

export { formatBytes, formatDuration, calculateStats, type Stats };
