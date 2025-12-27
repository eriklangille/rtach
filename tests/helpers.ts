import { spawn, spawnSync, type Subprocess } from "bun";
import { unlinkSync, existsSync, statSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { Socket } from "net";

// Path to rtach binary
export const RTACH_BIN = join(import.meta.dir, "../zig-out/bin/rtach");

// ============================================================================
// Process Registry - tracks all spawned processes for cleanup on test failure
// ============================================================================
const spawnedProcesses = new Set<Subprocess>();
const spawnedSockets = new Set<string>();

// Debug mode - set to true to see cleanup diagnostics
const DEBUG_CLEANUP = true;

function debugLog(...args: unknown[]) {
  if (DEBUG_CLEANUP) {
    console.log("[cleanup]", ...args);
  }
}

// Track a process for cleanup
export function trackProcess(proc: Subprocess): Subprocess {
  spawnedProcesses.add(proc);
  debugLog(`Tracking PID ${proc.pid}, total tracked: ${spawnedProcesses.size}`);
  proc.exited.then(() => {
    spawnedProcesses.delete(proc);
    debugLog(`PID ${proc.pid} exited naturally, remaining: ${spawnedProcesses.size}`);
  }).catch(() => spawnedProcesses.delete(proc));
  return proc;
}

// Track a socket path for cleanup
export function trackSocket(socketPath: string): string {
  spawnedSockets.add(socketPath);
  return socketPath;
}

// Find child PIDs of a process (macOS)
function getChildPids(parentPid: number): number[] {
  try {
    const result = spawnSync(["pgrep", "-P", parentPid.toString()]);
    const output = result.stdout.toString().trim();
    if (!output) return [];
    return output.split("\n").map((s) => parseInt(s, 10)).filter((n) => !isNaN(n));
  } catch {
    return [];
  }
}

// Find all PIDs matching a pattern (safety net for untracked processes)
function findProcessesByPattern(pattern: string): number[] {
  try {
    const result = spawnSync(["pgrep", "-f", pattern]);
    const output = result.stdout.toString().trim();
    if (!output) return [];
    return output.split("\n").map((s) => parseInt(s, 10)).filter((n) => !isNaN(n));
  } catch {
    return [];
  }
}

// Kill all tracked processes and clean up sockets - call in afterEach
export async function cleanupAll(): Promise<void> {
  debugLog(`cleanupAll called. Tracked processes: ${spawnedProcesses.size}, sockets: ${spawnedSockets.size}`);

  const killPromises: Promise<unknown>[] = [];
  const allPidsToKill: number[] = [];

  // SAFETY NET: Find ALL rtach-test processes (catches untracked spawns)
  const rtachTestPids = findProcessesByPattern("rtach-test");
  if (rtachTestPids.length > 0) {
    debugLog(`  Safety net: found ${rtachTestPids.length} rtach-test processes: ${rtachTestPids.join(", ")}`);
    for (const pid of rtachTestPids) {
      allPidsToKill.push(pid);
      // Also get their children
      const children = getChildPids(pid);
      allPidsToKill.push(...children);
    }
  }

  // Collect all PIDs including children
  for (const proc of spawnedProcesses) {
    debugLog(`  Processing tracked PID ${proc.pid}`);
    allPidsToKill.push(proc.pid);
    // Get child processes (rtach spawns /bin/cat, /bin/sh, etc.)
    const children = getChildPids(proc.pid);
    debugLog(`    Children of ${proc.pid}: ${children.join(", ") || "none"}`);
    allPidsToKill.push(...children);
    // Also get grandchildren
    for (const child of children) {
      const grandchildren = getChildPids(child);
      if (grandchildren.length > 0) {
        debugLog(`    Grandchildren of ${child}: ${grandchildren.join(", ")}`);
      }
      allPidsToKill.push(...grandchildren);
    }
  }

  debugLog(`  Total PIDs to kill: ${allPidsToKill.length} - [${allPidsToKill.join(", ")}]`);

  // Kill all collected PIDs
  for (const pid of allPidsToKill) {
    try {
      process.kill(pid, 9);
      debugLog(`  Killed PID ${pid}`);
    } catch (e) {
      debugLog(`  Failed to kill PID ${pid}: ${e}`);
    }
  }

  // Wait for tracked processes to exit
  for (const proc of spawnedProcesses) {
    killPromises.push(proc.exited.catch(() => {}));
  }
  spawnedProcesses.clear();

  await Promise.all(killPromises);
  debugLog(`  All tracked processes exited`);

  for (const socketPath of spawnedSockets) {
    cleanupSocket(socketPath);
  }
  spawnedSockets.clear();
  debugLog(`cleanupAll finished`);
}

// Generate unique socket path (auto-tracked for cleanup)
export function uniqueSocketPath(): string {
  const id = Math.random().toString(36).substring(2, 10);
  const socketPath = join(tmpdir(), `rtach-test-${id}.sock`);
  trackSocket(socketPath);
  return socketPath;
}

// Clean up socket file
export function cleanupSocket(socketPath: string): void {
  try {
    if (existsSync(socketPath)) {
      unlinkSync(socketPath);
    }
  } catch {
    // Ignore errors
  }
}

// Check if socket exists and is a socket file
export function socketExists(socketPath: string): boolean {
  try {
    const stat = statSync(socketPath);
    return stat.isSocket();
  } catch {
    return false;
  }
}

// Wait for socket to appear (with timeout)
export async function waitForSocket(
  socketPath: string,
  timeoutMs: number = 5000
): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (socketExists(socketPath)) {
      return true;
    }
    await Bun.sleep(50);
  }
  return false;
}

// Start rtach master in detached mode (auto-tracked for cleanup)
export async function startDetachedMaster(
  socketPath: string,
  command: string = "/bin/cat",
  scrollbackSize?: number
): Promise<Subprocess> {
  const args = ["-n", socketPath];
  if (scrollbackSize) {
    args.push("-s", scrollbackSize.toString());
  }
  args.push(command);

  const proc = spawn([RTACH_BIN, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  trackProcess(proc);

  // Wait for socket to be created
  const ready = await waitForSocket(socketPath);
  if (!ready) {
    proc.kill();
    throw new Error(`Master failed to create socket at ${socketPath}`);
  }

  return proc;
}

// Connect to rtach as a client (auto-tracked for cleanup)
export function connectClient(
  socketPath: string,
  options: {
    detachChar?: string;
    noDetachChar?: boolean;
    redrawMethod?: "none" | "ctrl_l" | "winch";
  } = {}
): Subprocess {
  const args = ["-a", socketPath];

  if (options.noDetachChar) {
    args.push("-E");
  } else if (options.detachChar) {
    args.push("-e", options.detachChar);
  }

  if (options.redrawMethod) {
    args.push("-r", options.redrawMethod);
  }

  const proc = spawn([RTACH_BIN, ...args], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  trackProcess(proc);
  return proc;
}

// Read from subprocess stdout with timeout
export async function readWithTimeout(
  proc: Subprocess,
  timeoutMs: number = 1000
): Promise<string> {
  const reader = proc.stdout?.getReader();
  if (!reader) {
    throw new Error("No stdout reader available");
  }

  const decoder = new TextDecoder();
  let result = "";

  const timeoutPromise = new Promise<null>((resolve) =>
    setTimeout(() => resolve(null), timeoutMs)
  );

  while (true) {
    const readPromise = reader.read();
    const value = await Promise.race([readPromise, timeoutPromise]);

    if (value === null) {
      // Timeout
      reader.releaseLock();
      break;
    }

    if (value.done) {
      reader.releaseLock();
      break;
    }

    result += decoder.decode(value.value, { stream: true });
  }

  return result;
}

// Store persistent readers per process to avoid Bun's reader re-acquisition limit
const processReaders = new WeakMap<
  Subprocess,
  {
    reader: ReadableStreamDefaultReader<Uint8Array>;
    buffer: string;
    decoder: TextDecoder;
    pendingRead: Promise<ReadableStreamReadResult<Uint8Array>> | null;
  }
>();

function getProcessReader(proc: Subprocess) {
  let state = processReaders.get(proc);
  if (!state) {
    const reader = proc.stdout?.getReader();
    if (!reader) {
      throw new Error("No stdout reader available");
    }
    state = {
      reader,
      buffer: "",
      decoder: new TextDecoder(),
      pendingRead: null,
    };
    processReaders.set(proc, state);
  }
  return state;
}

// Wait for specific output to appear in stdout
export async function waitForOutput(
  proc: Subprocess,
  pattern: string | RegExp,
  timeoutMs: number = 5000
): Promise<string> {
  const state = getProcessReader(proc);
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    // Check if pattern already in buffer
    const match =
      typeof pattern === "string"
        ? state.buffer.includes(pattern)
        : pattern.test(state.buffer);

    if (match) {
      return state.buffer;
    }

    // Read more data with timeout
    const remainingTime = timeoutMs - (Date.now() - startTime);
    const timeoutPromise = new Promise<null>((resolve) =>
      setTimeout(() => resolve(null), Math.min(remainingTime, 50))
    );

    // Start a read if we don't have one pending
    if (!state.pendingRead) {
      state.pendingRead = state.reader.read();
    }

    const result = await Promise.race([state.pendingRead, timeoutPromise]);

    if (result === null) {
      // Timeout from race - continue loop to check overall time
      continue;
    }

    // Got data
    state.pendingRead = null;

    if (result.done) {
      throw new Error("Stream ended unexpectedly");
    }

    if (result.value) {
      state.buffer += state.decoder.decode(result.value, { stream: true });
    }
  }

  throw new Error(`Timeout waiting for output matching: ${pattern}`);
}

// Wait for process to be ready to receive input by doing a write/read cycle
export async function waitForReady(
  proc: Subprocess,
  timeoutMs: number = 5000
): Promise<void> {
  const marker = `__READY_${Date.now()}_${Math.random().toString(36)}__`;

  // Write marker to stdin
  await writeToProc(proc, marker);

  // Wait for echo
  try {
    await waitForOutput(proc, marker, timeoutMs);
  } catch {
    throw new Error("Process not ready: no echo received");
  }
}

// Connect and wait for client to be attached
export async function connectAndWait(
  socketPath: string,
  options: {
    detachChar?: string;
    noDetachChar?: boolean;
    redrawMethod?: "none" | "ctrl_l" | "winch";
  } = {},
  timeoutMs: number = 5000
): Promise<Subprocess> {
  const client = connectClient(socketPath, options);

  // Verify connection by writing a marker and waiting for echo
  const marker = `__CONNECT_${Date.now()}__`;
  await writeToProc(client, marker);

  try {
    await waitForOutput(client, marker, timeoutMs);
  } catch {
    client.kill(9);
    throw new Error(`Failed to connect to ${socketPath}`);
  }

  return client;
}

// Write to subprocess stdin
export async function writeToProc(
  proc: Subprocess,
  data: string
): Promise<void> {
  if (!proc.stdin) {
    throw new Error("No stdin available");
  }
  // Bun's stdin is a FileSink with write() method
  proc.stdin.write(data);
  proc.stdin.flush();
}

// Kill process and wait for exit
export async function killAndWait(
  proc: Subprocess,
  signal: number = 15
): Promise<number | null> {
  proc.kill(signal);
  return await proc.exited;
}

// Measure memory usage of a process (macOS/Linux)
export function getProcessMemory(pid: number): number | null {
  try {
    if (process.platform === "darwin") {
      // macOS: use ps
      const result = spawnSync(["ps", "-o", "rss=", "-p", pid.toString()]);
      const output = result.stdout.toString().trim();
      return parseInt(output, 10) * 1024; // ps reports in KB, convert to bytes
    } else {
      // Linux: read from /proc
      const statm = Bun.file(`/proc/${pid}/statm`);
      const content = statm.text();
      const parts = content.toString().split(" ");
      const pages = parseInt(parts[1], 10); // RSS in pages
      return pages * 4096; // Assume 4KB pages
    }
  } catch {
    return null;
  }
}

// Format bytes to human readable
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

// Format duration in ms to human readable
export function formatDuration(ms: number): string {
  if (ms < 1) return `${(ms * 1000).toFixed(0)} µs`;
  if (ms < 1000) return `${ms.toFixed(2)} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

// Simple PTY-like test helper using a shell
export async function createTestSession(
  socketPath: string,
  scrollbackSize: number = 1024 * 1024
): Promise<{ master: Subprocess; cleanup: () => Promise<void> }> {
  const master = await startDetachedMaster(
    socketPath,
    "/bin/sh",
    scrollbackSize
  );

  return {
    master,
    cleanup: async () => {
      await killAndWait(master, 9);
      cleanupSocket(socketPath);
    },
  };
}

// Statistics helper
export interface Stats {
  min: number;
  max: number;
  mean: number;
  median: number;
  stdDev: number;
  p95: number;
  p99: number;
}

export function calculateStats(values: number[]): Stats {
  if (values.length === 0) {
    return { min: 0, max: 0, mean: 0, median: 0, stdDev: 0, p95: 0, p99: 0 };
  }

  const sorted = [...values].sort((a, b) => a - b);
  const sum = values.reduce((a, b) => a + b, 0);
  const mean = sum / values.length;

  const squaredDiffs = values.map((v) => Math.pow(v - mean, 2));
  const variance = squaredDiffs.reduce((a, b) => a + b, 0) / values.length;
  const stdDev = Math.sqrt(variance);

  const percentile = (p: number) => {
    const index = Math.ceil((p / 100) * sorted.length) - 1;
    return sorted[Math.max(0, index)];
  };

  return {
    min: sorted[0],
    max: sorted[sorted.length - 1],
    mean,
    median: sorted[Math.floor(sorted.length / 2)],
    stdDev,
    p95: percentile(95),
    p99: percentile(99),
  };
}

// ============================================================================
// Raw Socket Protocol Helpers (for testing protocol messages directly)
// ============================================================================

// Protocol message types
export const MessageType = {
  PUSH: 0,
  ATTACH: 1,
  DETACH: 2,
  WINCH: 3,
  REDRAW: 4,
  REQUEST_SCROLLBACK: 5,
  REQUEST_SCROLLBACK_PAGE: 6,
  UPGRADE: 7,
} as const;

export const ResponseType = {
  TERMINAL_DATA: 0,
  SCROLLBACK: 1,
  COMMAND: 2,
  SCROLLBACK_PAGE: 3,
  HANDSHAKE: 255,
} as const;

// Protocol constants
export const RESPONSE_HEADER_SIZE = 5;
export const HANDSHAKE_SIZE = 8;
export const HANDSHAKE_MAGIC = 0x48435452; // "RTCH"

// Raw socket connection to rtach master
export interface RawRtachConnection {
  socket: Socket;
  dataBuffer: Buffer;
  close: () => void;
}

// Connect to rtach socket directly (bypassing CLI)
export function connectRawSocket(socketPath: string): Promise<RawRtachConnection> {
  return new Promise((resolve, reject) => {
    const socket = new Socket();
    const conn: RawRtachConnection = {
      socket,
      dataBuffer: Buffer.alloc(0),
      close: () => socket.destroy(),
    };

    socket.on("data", (data) => {
      conn.dataBuffer = Buffer.concat([conn.dataBuffer, data]);
    });

    socket.on("error", reject);

    socket.connect(socketPath, () => {
      resolve(conn);
    });
  });
}

// Wait for handshake and send upgrade packet
export async function handleProtocolUpgrade(
  conn: RawRtachConnection,
  timeoutMs: number = 5000
): Promise<void> {
  const startTime = Date.now();
  const handshakeFrameSize = RESPONSE_HEADER_SIZE + HANDSHAKE_SIZE;

  // Wait for handshake frame
  while (Date.now() - startTime < timeoutMs) {
    if (conn.dataBuffer.length >= handshakeFrameSize) {
      const type = conn.dataBuffer[0];
      const len = conn.dataBuffer.readUInt32LE(1);

      if (type === ResponseType.HANDSHAKE && len === HANDSHAKE_SIZE) {
        // Parse and validate handshake
        const magic = conn.dataBuffer.readUInt32LE(RESPONSE_HEADER_SIZE);
        if (magic === HANDSHAKE_MAGIC) {
          // Remove handshake from buffer
          conn.dataBuffer = conn.dataBuffer.subarray(handshakeFrameSize);

          // Send upgrade packet: [type=7][len=0]
          const upgradePacket = Buffer.from([MessageType.UPGRADE, 0]);
          conn.socket.write(upgradePacket);
          return;
        }
      }
    }
    await Bun.sleep(10);
  }

  throw new Error("Timeout waiting for handshake");
}

// Connect and perform protocol upgrade
export async function connectRawSocketWithUpgrade(
  socketPath: string,
  timeoutMs: number = 5000
): Promise<RawRtachConnection> {
  const conn = await connectRawSocket(socketPath);
  await handleProtocolUpgrade(conn, timeoutMs);
  return conn;
}

// Send attach packet with client_id
export function sendAttachPacket(conn: RawRtachConnection, clientId: string = "test-client"): void {
  // Attach packet: [type=1][len][cols:2][rows:2][client_id...]
  const clientIdBytes = Buffer.from(clientId, "utf8");
  const len = 4 + clientIdBytes.length; // 2 cols + 2 rows + client_id
  const packet = Buffer.alloc(2 + len);
  packet[0] = MessageType.ATTACH;
  packet[1] = len;
  packet.writeUInt16LE(80, 2); // cols
  packet.writeUInt16LE(24, 4); // rows
  clientIdBytes.copy(packet, 6);
  conn.socket.write(packet);
}

// Send request_scrollback_page packet
export function sendScrollbackPageRequest(
  conn: RawRtachConnection,
  offset: number,
  limit: number
): void {
  // Packet: [type=6][len=8][offset:4 LE][limit:4 LE]
  const packet = Buffer.alloc(10);
  packet[0] = MessageType.REQUEST_SCROLLBACK_PAGE;
  packet[1] = 8; // payload length
  packet.writeUInt32LE(offset, 2);
  packet.writeUInt32LE(limit, 6);
  conn.socket.write(packet);
}

// Send legacy request_scrollback packet
export function sendScrollbackRequest(conn: RawRtachConnection): void {
  // Packet: [type=5][len=0]
  const packet = Buffer.from([MessageType.REQUEST_SCROLLBACK, 0]);
  conn.socket.write(packet);
}

// Parse response header (5 bytes: type + 4-byte length)
export interface ResponseHeader {
  type: number;
  length: number;
}

export function parseResponseHeader(data: Buffer): ResponseHeader | null {
  if (data.length < 5) return null;
  return {
    type: data[0],
    length: data.readUInt32LE(1),
  };
}

// Parse scrollback_page metadata (8 bytes: total_len + offset)
export interface ScrollbackPageMeta {
  totalLen: number;
  offset: number;
}

export function parseScrollbackPageMeta(data: Buffer): ScrollbackPageMeta | null {
  if (data.length < 8) return null;
  return {
    totalLen: data.readUInt32LE(0),
    offset: data.readUInt32LE(4),
  };
}

// Wait for scrollback_page response and parse it
export async function waitForScrollbackPageResponse(
  conn: RawRtachConnection,
  timeoutMs: number = 5000
): Promise<{ meta: ScrollbackPageMeta; data: Buffer }> {
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    // Need at least 5 bytes for header
    if (conn.dataBuffer.length >= 5) {
      const header = parseResponseHeader(conn.dataBuffer);
      if (header && header.type === ResponseType.SCROLLBACK_PAGE) {
        // Need header (5) + full response (header.length)
        const totalNeeded = 5 + header.length;
        if (conn.dataBuffer.length >= totalNeeded) {
          // Extract response
          const responseData = conn.dataBuffer.subarray(5, totalNeeded);
          // Remove processed data from buffer
          conn.dataBuffer = conn.dataBuffer.subarray(totalNeeded);

          // Parse metadata (first 8 bytes of response)
          const meta = parseScrollbackPageMeta(responseData);
          if (!meta) throw new Error("Failed to parse scrollback page metadata");

          // Remaining is scrollback data
          const scrollbackData = responseData.subarray(8);
          return { meta, data: scrollbackData };
        }
      }
    }
    await Bun.sleep(10);
  }

  throw new Error("Timeout waiting for scrollback_page response");
}

// Wait for legacy scrollback response
export async function waitForScrollbackResponse(
  conn: RawRtachConnection,
  timeoutMs: number = 5000
): Promise<Buffer> {
  const startTime = Date.now();

  while (Date.now() - startTime < timeoutMs) {
    if (conn.dataBuffer.length >= 5) {
      const header = parseResponseHeader(conn.dataBuffer);
      if (header && header.type === ResponseType.SCROLLBACK) {
        const totalNeeded = 5 + header.length;
        if (conn.dataBuffer.length >= totalNeeded) {
          const data = conn.dataBuffer.subarray(5, totalNeeded);
          conn.dataBuffer = conn.dataBuffer.subarray(totalNeeded);
          return data;
        }
      }
    }
    await Bun.sleep(10);
  }

  throw new Error("Timeout waiting for scrollback response");
}
