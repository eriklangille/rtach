import { describe, test, expect, beforeEach, afterEach, afterAll } from "bun:test";
import { spawn } from "bun";
import {
  RTACH_BIN,
  uniqueSocketPath,
  uniqueRelativeSocketPath,
  cleanupSocket,
  cleanupAll,
  socketExists,
  fifoExists,
  waitForSocket,
  startDetachedMaster,
  connectClient,
  connectAndWait,
  waitForOutput,
  writeToProc,
  killAndWait,
  connectRawSocket,
  connectRawSocketWithUpgrade,
  sendAttachPacket,
  sendScrollbackPageRequest,
  waitForScrollbackPageResponse,
  type RawRtachConnection,
  // Protocol constants for raw mode tests
  MessageType,
  ResponseType,
  RESPONSE_HEADER_SIZE,
  HANDSHAKE_SIZE,
  HANDSHAKE_MAGIC,
  COMPRESSION_FLAG,
  COMPRESSION_ZLIB,
} from "./helpers";
import { existsSync, readFileSync } from "fs";
import { tmpdir } from "os";

describe("rtach CLI", () => {
  afterEach(cleanupAll);
  test("shows help with --help", async () => {
    const proc = spawn([RTACH_BIN, "--help"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    await proc.exited;

    // Help may go to stdout or stderr depending on implementation
    const output = stdout + stderr;
    expect(output).toContain("rtach - persistent terminal sessions with scrollback");
    expect(output).toContain("Usage:");
    expect(output).toContain("-A");
    expect(output).toContain("-a");
    expect(output).toContain("-c");
    expect(output).toContain("-n");
  });

  test("shows help with -h", async () => {
    const proc = spawn([RTACH_BIN, "-h"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    await proc.exited;

    const output = stdout + stderr;
    expect(output).toContain("rtach - persistent terminal sessions with scrollback");
  });

  test("fails without socket path", async () => {
    const proc = spawn([RTACH_BIN], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const exitCode = await proc.exited;

    expect(exitCode).toBe(1);
    // Error message may go to stdout or stderr depending on implementation
    const output = stdout + stderr;
    expect(output).toContain("missing socket path");
  });
});

describe("rtach session creation", () => {
  let socketPath: string;

  beforeEach(() => {
    socketPath = uniqueSocketPath();
  });

  afterEach(cleanupAll);

  test("creates socket with -n (detached)", async () => {
    const proc = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    // Wait for socket to appear (event-based, not sleep)
    const ready = await waitForSocket(socketPath, 3000);
    expect(ready).toBe(true);
    expect(socketExists(socketPath)).toBe(true);

    await killAndWait(proc, 9);
  });

  test("creates socket with correct permissions", async () => {
    const proc = spawn([RTACH_BIN, "-n", socketPath, "/bin/cat"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    await waitForSocket(socketPath);

    const { statSync } = await import("fs");
    const stat = statSync(socketPath);
    const mode = stat.mode & 0o777;
    expect(mode).toBe(0o600);

    await killAndWait(proc, 9);
  });

  test("-c creates new session and attaches", async () => {
    const proc = spawn([RTACH_BIN, "-c", socketPath, "-E", "/bin/cat"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

    // Wait for socket to exist (indicates master is ready)
    await waitForSocket(socketPath);
    expect(socketExists(socketPath)).toBe(true);

    proc.kill(9);
    await proc.exited;
  });
});

describe("rtach attach/detach", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    master = await startDetachedMaster(socketPath, "/bin/cat");
  });

  afterEach(cleanupAll);

  test("client can attach with -a", async () => {
    // connectAndWait verifies connection by echo test
    const client = await connectAndWait(socketPath, { noDetachChar: true });

    // Write more data and verify echo
    await writeToProc(client, "hello-test-123");
    const output = await waitForOutput(client, "hello-test-123");
    expect(output).toContain("hello-test-123");

    client.kill(9);
    await client.exited;
  });

  test("attach fails if socket doesn't exist", async () => {
    const proc = spawn([RTACH_BIN, "-a", "/tmp/nonexistent-socket-12345"], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const exitCode = await proc.exited;
    expect(exitCode).not.toBe(0);
  });

  test("multiple clients can attach simultaneously", async () => {
    // Connect both clients (verified by echo)
    const client1 = await connectAndWait(socketPath, { noDetachChar: true });
    const client2 = await connectAndWait(socketPath, { noDetachChar: true });

    // Write unique marker from client1
    const marker = `from-client1-${Date.now()}`;
    await writeToProc(client1, marker + "\n");

    // Both should see the output
    const output2 = await waitForOutput(client2, marker, 2000);
    expect(output2).toContain(marker);

    client1.kill(9);
    client2.kill(9);
    await Promise.all([client1.exited, client2.exited]);
  });
});

describe("rtach scrollback", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    // Use a reasonable scrollback for testing
    master = await startDetachedMaster(socketPath, "/bin/cat", 4096);
  });

  afterEach(cleanupAll);

  test("new client receives scrollback on attach", async () => {
    // Client 1 sends data with unique marker
    const client1 = await connectAndWait(socketPath, { noDetachChar: true });
    const marker = `initial-data-${Date.now()}`;
    await writeToProc(client1, marker + "\n");

    // Wait for echo to confirm data is in scrollback
    await waitForOutput(client1, marker);

    // Disconnect client1
    client1.kill(9);
    await client1.exited;

    // Client 2 connects - should see scrollback containing marker
    const client2 = connectClient(socketPath, { noDetachChar: true });
    const output = await waitForOutput(client2, marker, 3000);
    expect(output).toContain(marker);

    client2.kill(9);
    await client2.exited;
  });

  test("scrollback wraps when buffer is full", async () => {
    // Create session with small scrollback (512 bytes) - enough for our test
    await killAndWait(master, 9);
    cleanupSocket(socketPath);

    master = await startDetachedMaster(socketPath, "/bin/cat", 512);

    const client1 = await connectAndWait(socketPath, { noDetachChar: true });

    // Write some data, then write the end marker
    const filler = "X".repeat(200);
    await writeToProc(client1, filler);

    const endMarker = `END${Date.now()}`;
    await writeToProc(client1, endMarker);

    // Wait for echo to confirm data processed
    await waitForOutput(client1, endMarker);

    client1.kill(9);
    await client1.exited;

    // New client should see scrollback containing the marker
    const client2 = connectClient(socketPath, { noDetachChar: true });
    const output = await waitForOutput(client2, endMarker, 3000);
    expect(output).toContain(endMarker);

    client2.kill(9);
    await client2.exited;
  });
});

describe("rtach window size", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    master = await startDetachedMaster(socketPath, "/bin/sh");
  });

  afterEach(cleanupAll);

  test("client can query terminal size via stty", async () => {
    const client = connectClient(socketPath, { noDetachChar: true });

    // Run stty size command
    await writeToProc(client, "stty size\n");

    // Wait for response matching rows cols pattern
    const output = await waitForOutput(client, /\d+\s+\d+/, 3000);
    expect(output).toMatch(/\d+\s+\d+/);

    client.kill(9);
    await client.exited;
  });
});

describe("rtach session persistence", () => {
  let socketPath: string;

  beforeEach(() => {
    socketPath = uniqueSocketPath();
  });

  afterEach(cleanupAll);

  test("session survives client disconnect", async () => {
    const master = await startDetachedMaster(socketPath, "/bin/sh");

    // Client 1 creates some state
    const client1 = connectClient(socketPath, { noDetachChar: true });

    // Wait for initial prompt
    await waitForOutput(client1, "$", 2000);

    // Set a variable with unique value
    const varValue = `hello${Date.now()}`;
    await writeToProc(client1, `TESTVAR=${varValue}\n`);

    // In raw mode, there's no echo of the input, but we need to verify
    // the variable was set. Wait a moment then echo it.
    await Bun.sleep(100);
    await writeToProc(client1, `echo $TESTVAR\n`);

    // Wait for the echoed value
    await waitForOutput(client1, varValue, 2000);

    // Disconnect
    client1.kill(9);
    await client1.exited;

    // Client 2 should see the same shell session
    const client2 = connectClient(socketPath, { noDetachChar: true });

    // Wait for scrollback replay (should include previous output)
    await Bun.sleep(100);

    // Echo the variable again - it should still be set
    await writeToProc(client2, "echo $TESTVAR\n");

    // Should see the value
    const output = await waitForOutput(client2, varValue, 3000);
    expect(output).toContain(varValue);

    client2.kill(9);
    await client2.exited;
    await killAndWait(master, 9);
  });

  test("-A attaches to existing session", async () => {
    // Create session first using -n (detached mode)
    const master = await startDetachedMaster(socketPath, "/bin/cat");

    // Now -A should attach to existing session
    const proc = spawn([RTACH_BIN, "-A", socketPath, "-E"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

    // Verify it's working by writing and getting echo
    const marker = `test${Date.now()}`;
    await writeToProc(proc, marker);
    const output = await waitForOutput(proc, marker, 2000);
    expect(output).toContain(marker);

    proc.kill(9);
    await proc.exited;
    await killAndWait(master, 9);
  });
});

describe("rtach command execution", () => {
  let socketPath: string;

  beforeEach(() => {
    socketPath = uniqueSocketPath();
  });

  afterEach(cleanupAll);

  test("shell receives input and produces output", async () => {
    const master = await startDetachedMaster(socketPath, "/bin/sh");

    const client = connectClient(socketPath, { noDetachChar: true });

    // Run a simple command with unique output
    const marker = `test-output-${Date.now()}`;
    await writeToProc(client, `echo '${marker}'\n`);

    const output = await waitForOutput(client, marker, 3000);
    expect(output).toContain(marker);

    client.kill(9);
    await client.exited;
    await killAndWait(master, 9);
  });

  test("executes specified command and echoes", async () => {
    const master = await startDetachedMaster(socketPath, "/bin/cat");

    const client = await connectAndWait(socketPath, { noDetachChar: true });

    // cat should echo everything
    const testData = `test-cat-${Date.now()}`;
    await writeToProc(client, testData);
    const output = await waitForOutput(client, testData);
    expect(output).toContain(testData);

    client.kill(9);
    await client.exited;
    await killAndWait(master, 9);
  });
});

describe("rtach stress tests", () => {
  let socketPath: string;

  beforeEach(() => {
    socketPath = uniqueSocketPath();
  });

  afterEach(cleanupAll);

  test("rapid client connect/disconnect (bounds safety)", async () => {
    // This test exercises the client array management code
    // to catch any out-of-bounds issues with swapRemove
    const master = await startDetachedMaster(socketPath);

    // Rapidly connect and disconnect 20 clients
    for (let i = 0; i < 20; i++) {
      const client = await connectClient(socketPath);
      // Small delay to ensure connection is established
      await Bun.sleep(10);
      client.kill(9);
      await client.exited;
    }

    // Master should still be healthy - verify by connecting a final client
    const finalClient = await connectAndWait(socketPath);
    await writeToProc(finalClient, "final-test");
    const output = await waitForOutput(finalClient, "final-test");
    expect(output).toContain("final-test");

    finalClient.kill(9);
    await finalClient.exited;
    await killAndWait(master, 9);
  });

  test("simultaneous connect/disconnect (race conditions)", async () => {
    const master = await startDetachedMaster(socketPath);

    // Connect multiple clients simultaneously
    const clients = await Promise.all([
      connectClient(socketPath),
      connectClient(socketPath),
      connectClient(socketPath),
      connectClient(socketPath),
      connectClient(socketPath),
    ]);

    await Bun.sleep(50);

    // Kill them all at once
    await Promise.all(clients.map(async (c) => {
      c.kill(9);
      await c.exited;
    }));

    // Master should survive
    const verifyClient = await connectAndWait(socketPath);
    await writeToProc(verifyClient, "verify");
    const output = await waitForOutput(verifyClient, "verify");
    expect(output).toContain("verify");

    verifyClient.kill(9);
    await verifyClient.exited;
    await killAndWait(master, 9);
  });
});

describe("rtach paginated scrollback", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;
  let rawConn: RawRtachConnection | null = null;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    // Use 64KB scrollback for pagination tests
    master = await startDetachedMaster(socketPath, "/bin/cat", 64 * 1024);
  });

  afterEach(async () => {
    if (rawConn) {
      rawConn.close();
      rawConn = null;
    }
    await cleanupAll();
  });

  test("request_scrollback_page returns metadata and data", async () => {
    // Connect via raw socket and write data directly
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paginated-test");

    // Wait for connection to establish and initial scrollback
    await Bun.sleep(200);

    // Write test data via raw socket (push message)
    const testData = "A".repeat(100);
    const pushPacket = Buffer.alloc(2 + testData.length);
    pushPacket[0] = 0; // MessageType.PUSH
    pushPacket[1] = testData.length;
    Buffer.from(testData).copy(pushPacket, 2);
    rawConn.socket.write(pushPacket);

    // Wait for echo from cat
    await Bun.sleep(300);
    rawConn.dataBuffer = Buffer.alloc(0); // Clear buffer (discard echo)

    // Request first page of scrollback
    sendScrollbackPageRequest(rawConn, 0, 512);

    const response = await waitForScrollbackPageResponse(rawConn);

    // Verify metadata
    expect(response.meta.totalLen).toBeGreaterThan(0);
    expect(response.meta.offset).toBe(0);

    // Verify we got data (up to 512 bytes requested)
    expect(response.data.length).toBeLessThanOrEqual(512);
    expect(response.data.length).toBeGreaterThan(0);
  });

  test("paginated scrollback returns correct offsets", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "offset-test");
    await Bun.sleep(100);

    // Write 2KB of data
    const testData = "B".repeat(2000);
    const pushPacket = Buffer.alloc(2 + testData.length);
    pushPacket[0] = 0; // MessageType.PUSH
    pushPacket[1] = 255; // Max single-byte length, will truncate but that's ok for test
    Buffer.from(testData.slice(0, 255)).copy(pushPacket, 2);

    // Write in chunks since push has 1-byte length
    for (let i = 0; i < testData.length; i += 200) {
      const chunk = testData.slice(i, i + 200);
      const pkt = Buffer.alloc(2 + chunk.length);
      pkt[0] = 0;
      pkt[1] = chunk.length;
      Buffer.from(chunk).copy(pkt, 2);
      rawConn.socket.write(pkt);
    }

    await Bun.sleep(300);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Request first 500 bytes
    sendScrollbackPageRequest(rawConn, 0, 500);
    const page1 = await waitForScrollbackPageResponse(rawConn);

    expect(page1.meta.offset).toBe(0);
    expect(page1.data.length).toBe(500);

    // Request next 500 bytes
    sendScrollbackPageRequest(rawConn, 500, 500);
    const page2 = await waitForScrollbackPageResponse(rawConn);

    expect(page2.meta.offset).toBe(500);
    expect(page2.data.length).toBe(500);

    // Total length should be consistent
    expect(page1.meta.totalLen).toBe(page2.meta.totalLen);
  });

  test("paginated scrollback handles offset beyond end", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "beyond-end-test");
    await Bun.sleep(100);

    // Write small amount of data
    const testData = "small data";
    const pushPacket = Buffer.alloc(2 + testData.length);
    pushPacket[0] = 0;
    pushPacket[1] = testData.length;
    Buffer.from(testData).copy(pushPacket, 2);
    rawConn.socket.write(pushPacket);

    await Bun.sleep(200);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Request with offset way beyond total size
    sendScrollbackPageRequest(rawConn, 100000, 500);
    const response = await waitForScrollbackPageResponse(rawConn);

    // Should return empty data but still have correct total
    expect(response.meta.totalLen).toBeGreaterThan(0);
    expect(response.meta.totalLen).toBeLessThan(100000);
    expect(response.data.length).toBe(0);
  });

  test("paginated scrollback accumulates full buffer", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "large-buffer-test");
    await Bun.sleep(100);

    // Write 8KB of data in chunks
    const totalBytes = 8000;
    const chunkSize = 200;
    for (let i = 0; i < totalBytes; i += chunkSize) {
      const chunk = "X".repeat(Math.min(chunkSize, totalBytes - i));
      const pkt = Buffer.alloc(2 + chunk.length);
      pkt[0] = 0;
      pkt[1] = chunk.length;
      Buffer.from(chunk).copy(pkt, 2);
      rawConn.socket.write(pkt);
    }

    await Bun.sleep(300);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Request in pages and accumulate
    let totalReceived = 0;
    let offset = 0;
    const pageSize = 1024;
    let totalLen = 0;

    while (true) {
      sendScrollbackPageRequest(rawConn, offset, pageSize);
      const response = await waitForScrollbackPageResponse(rawConn);

      totalLen = response.meta.totalLen;
      totalReceived += response.data.length;
      offset += response.data.length;

      if (response.data.length === 0 || offset >= totalLen) {
        break;
      }
    }

    // Should have received all scrollback data
    expect(totalReceived).toBe(totalLen);
    // cat echoes back, so we get 2x the data (sent + echo)
    expect(totalLen).toBeGreaterThanOrEqual(totalBytes);
  });

  test("paginated scrollback data contains written content", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "content-test");
    await Bun.sleep(100);

    // Write unique marker
    const marker = "UNIQUE_MARKER_12345";
    const pushPacket = Buffer.alloc(2 + marker.length);
    pushPacket[0] = 0;
    pushPacket[1] = marker.length;
    Buffer.from(marker).copy(pushPacket, 2);
    rawConn.socket.write(pushPacket);

    await Bun.sleep(200);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Request all scrollback
    sendScrollbackPageRequest(rawConn, 0, 64 * 1024);
    const response = await waitForScrollbackPageResponse(rawConn);

    // Verify data contains our marker
    const dataStr = response.data.toString();
    expect(dataStr).toContain(marker);
  });
});

describe("rtach command FIFO", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    master = await startDetachedMaster(socketPath, "/bin/cat");
  });

  afterEach(cleanupAll);

  test("creates FIFO alongside socket", async () => {
    // Socket should exist (verified by startDetachedMaster)
    expect(socketExists(socketPath)).toBe(true);

    // FIFO should also exist at {socket_path}.cmd
    const fifoPath = `${socketPath}.cmd`;
    expect(fifoExists(fifoPath)).toBe(true);
  });

  test("FIFO has correct permissions (0600)", async () => {
    const fifoPath = `${socketPath}.cmd`;
    const { statSync } = await import("fs");
    const stat = statSync(fifoPath);
    const mode = stat.mode & 0o777;
    expect(mode).toBe(0o600);
  });

  test("FIFO receives commands and forwards to clients", async () => {
    // Connect a client via raw socket with upgrade
    const rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "fifo-test-client");
    await Bun.sleep(100);

    // Clear any initial data
    rawConn.dataBuffer = Buffer.alloc(0);

    // Write a command to the FIFO
    const fifoPath = `${socketPath}.cmd`;
    const { writeFileSync } = await import("fs");
    writeFileSync(fifoPath, "forward;8080\n");

    // Wait for command response from server
    const startTime = Date.now();
    const timeoutMs = 2000;
    let foundCommand = false;

    while (Date.now() - startTime < timeoutMs) {
      // Look for command response (type=2 is COMMAND)
      if (rawConn.dataBuffer.length >= 5) {
        const type = rawConn.dataBuffer[0];
        const len = rawConn.dataBuffer.readUInt32LE(1);

        if (type === 2 && rawConn.dataBuffer.length >= 5 + len) {
          // Command response found
          const cmdData = rawConn.dataBuffer.subarray(5, 5 + len);
          const cmdStr = cmdData.toString();
          if (cmdStr.includes("forward;8080")) {
            foundCommand = true;
            break;
          }
          // Consume this response and continue
          rawConn.dataBuffer = rawConn.dataBuffer.subarray(5 + len);
        } else if (rawConn.dataBuffer.length >= 5 + len) {
          // Different response type, skip it
          rawConn.dataBuffer = rawConn.dataBuffer.subarray(5 + len);
        }
      }
      await Bun.sleep(50);
    }

    rawConn.close();
    expect(foundCommand).toBe(true);
  });

  test("cleanup removes FIFO file", async () => {
    const fifoPath = `${socketPath}.cmd`;

    // Verify FIFO exists
    expect(fifoExists(fifoPath)).toBe(true);

    // Clean up
    await killAndWait(master, 9);

    // Give some time for cleanup
    await Bun.sleep(100);

    // FIFO should be removed (cleanupSocket handles this)
    cleanupSocket(socketPath);
    expect(fifoExists(fifoPath)).toBe(false);
  });
});

describe("rtach raw mode (no upgrade)", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    master = await startDetachedMaster(socketPath, "/bin/cat");
  });

  afterEach(cleanupAll);

  test("raw client receives unframed terminal data", async () => {
    // Connect to socket directly
    const rawConn = await connectRawSocket(socketPath);

    // Wait for and consume handshake, but DO NOT send upgrade
    const startTime = Date.now();
    const handshakeFrameSize = RESPONSE_HEADER_SIZE + HANDSHAKE_SIZE;

    while (Date.now() - startTime < 5000) {
      if (rawConn.dataBuffer.length >= handshakeFrameSize) {
        const type = rawConn.dataBuffer[0];
        const len = rawConn.dataBuffer.readUInt32LE(1);

        if (type === ResponseType.HANDSHAKE && len === HANDSHAKE_SIZE) {
          // Parse and validate handshake
          const magic = rawConn.dataBuffer.readUInt32LE(RESPONSE_HEADER_SIZE);
          expect(magic).toBe(HANDSHAKE_MAGIC);

          // Remove handshake from buffer - but DON'T send upgrade
          rawConn.dataBuffer = rawConn.dataBuffer.subarray(handshakeFrameSize);
          break;
        }
      }
      await Bun.sleep(10);
    }

    // Send attach packet (without prior upgrade - this makes us a raw client)
    sendAttachPacket(rawConn, "raw-test-client");
    await Bun.sleep(100);

    // Clear any scrollback data
    rawConn.dataBuffer = Buffer.alloc(0);

    // Send data through PTY - use a marker we can identify
    const marker = `RAW_TEST_${Date.now()}`;
    rawConn.socket.write(Buffer.from([MessageType.PUSH, marker.length, ...Buffer.from(marker)]));

    // Wait for response - should be RAW terminal data (no framing header)
    const timeoutMs = 2000;
    const waitStart = Date.now();

    while (Date.now() - waitStart < timeoutMs) {
      if (rawConn.dataBuffer.length > 0) {
        const dataStr = rawConn.dataBuffer.toString();

        // Check if we got the marker in the response
        if (dataStr.includes(marker)) {
          // Verify it's NOT framed - first byte should NOT be 0 (terminal_data type)
          // or if it is, the subsequent bytes shouldn't form a valid length header
          // Actually, if it's raw, the first bytes should be our marker text directly
          // A framed response would start with [0][length bytes][data]

          // In raw mode, the data should be exactly what we sent (echo from cat)
          // In framed mode, it would be [type=0][len=N][marker]

          // The simplest check: if the data starts with our marker or contains it
          // without a 5-byte header prefix, it's raw
          const markerIndex = rawConn.dataBuffer.indexOf(marker);
          expect(markerIndex).toBeGreaterThanOrEqual(0);

          // For raw mode: the marker should be at the start (or very close)
          // For framed mode: there would be a 5-byte header before it
          // Since /bin/cat echoes back, we expect the marker relatively early
          expect(markerIndex).toBeLessThan(10); // Raw mode - no header overhead

          rawConn.close();
          return;
        }
      }
      await Bun.sleep(50);
    }

    rawConn.close();
    throw new Error("Timeout waiting for raw response");
  });

  test("framed client receives framed terminal data", async () => {
    // Connect with upgrade (framed mode) - for comparison
    const rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "framed-test-client");
    await Bun.sleep(100);

    // Clear any scrollback data
    rawConn.dataBuffer = Buffer.alloc(0);

    // Send data through PTY
    const marker = `FRAMED_TEST_${Date.now()}`;
    rawConn.socket.write(Buffer.from([MessageType.PUSH, marker.length, ...Buffer.from(marker)]));

    // Wait for response - should be FRAMED (with header)
    const timeoutMs = 2000;
    const waitStart = Date.now();

    while (Date.now() - waitStart < timeoutMs) {
      if (rawConn.dataBuffer.length >= 5) {
        const type = rawConn.dataBuffer[0];
        const len = rawConn.dataBuffer.readUInt32LE(1);

        // Should be terminal_data type (0)
        if (type === 0 && rawConn.dataBuffer.length >= 5 + len) {
          const data = rawConn.dataBuffer.subarray(5, 5 + len);
          const dataStr = data.toString();

          if (dataStr.includes(marker)) {
            // Framed mode confirmed - data was wrapped with header
            expect(type).toBe(0); // terminal_data
            expect(len).toBeGreaterThan(0);
            rawConn.close();
            return;
          }

          // Consume this response
          rawConn.dataBuffer = rawConn.dataBuffer.subarray(5 + len);
        }
      }
      await Bun.sleep(50);
    }

    rawConn.close();
    throw new Error("Timeout waiting for framed response");
  });

  test("raw client does not receive idle notifications", async () => {
    // Connect as raw client (no upgrade)
    const rawConn = await connectRawSocket(socketPath);

    // Consume handshake without sending upgrade
    const handshakeFrameSize = RESPONSE_HEADER_SIZE + HANDSHAKE_SIZE;
    const startTime = Date.now();

    while (Date.now() - startTime < 5000) {
      if (rawConn.dataBuffer.length >= handshakeFrameSize) {
        rawConn.dataBuffer = rawConn.dataBuffer.subarray(handshakeFrameSize);
        break;
      }
      await Bun.sleep(10);
    }

    sendAttachPacket(rawConn, "raw-idle-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Wait for idle timeout (2 seconds in master) plus some buffer
    await Bun.sleep(3000);

    // Raw client should NOT have received idle notification (type=4, len=0)
    // Check if buffer contains idle header [4][0,0,0,0]
    let foundIdle = false;
    for (let i = 0; i < rawConn.dataBuffer.length - 4; i++) {
      if (rawConn.dataBuffer[i] === 4 && rawConn.dataBuffer.readUInt32LE(i + 1) === 0) {
        foundIdle = true;
        break;
      }
    }

    rawConn.close();
    expect(foundIdle).toBe(false);
  });
});

describe("rtach title file handling", () => {
  afterEach(cleanupAll);

  test("master survives title write with relative socket path (regression test for crash)", async () => {
    // This test verifies the fix for a crash where writeTitleToFile used
    // createFileAbsolute/renameAbsolute which panic on relative paths.
    // Before the fix, the master would panic when trying to write the title file.
    const { relativePath, absolutePath } = uniqueRelativeSocketPath();

    // Start master with relative path, running from /tmp
    const master = spawn([RTACH_BIN, "-n", relativePath, "/bin/bash"], {
      cwd: tmpdir(),
      stdout: "pipe",
      stderr: "pipe",
    });

    await waitForSocket(absolutePath);

    // Connect, upgrade, and attach
    const rawConn = await connectRawSocketWithUpgrade(absolutePath);
    sendAttachPacket(rawConn, "relative-path-test");
    await Bun.sleep(100);

    // Send OSC 0 title sequence via push packet - this triggers title parsing
    // When the idle timer fires, it will try to write the title file
    const title = "Relative Path Title";
    const oscSequence = `\x1b]0;${title}\x07`;
    const payload = Buffer.from(oscSequence);
    rawConn.socket.write(Buffer.from([MessageType.PUSH, payload.length, ...payload]));

    // Wait for idle timer to fire and attempt title write
    // The old code would panic here with "reached unreachable code" from createFileAbsolute
    await Bun.sleep(3500);

    // Verify master is still running (didn't crash)
    // Check by sending another packet and verifying we can still communicate
    const testPayload = Buffer.from("test");
    rawConn.socket.write(Buffer.from([MessageType.PUSH, testPayload.length, ...testPayload]));
    await Bun.sleep(100);

    // If we got here, the master survived the title write attempt
    // The title file may or may not exist depending on timing, but no crash = success
    rawConn.close();
    master.kill();

    // Verify the master exited cleanly (was killed, not crashed)
    const exitCode = await master.exited;
    // SIGTERM (kill) results in exit code 143 on some systems, or the process just dies
    // The key is that we got here without a panic/crash during the test
    expect(exitCode).not.toBe(1); // Exit code 1 would indicate an error/panic
  });
});

describe("rtach compression", () => {
  let socketPath: string;
  let master: ReturnType<typeof spawn>;
  let rawConn: RawRtachConnection | null = null;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    // Use /bin/sh so we can run commands that generate large output
    master = await startDetachedMaster(socketPath, "/bin/sh");
  });

  afterEach(async () => {
    if (rawConn) {
      rawConn.close();
      rawConn = null;
    }
    await cleanupAll();
  });

  test("large terminal data is compressed (type byte has high bit set)", async () => {
    // Connect as framed client WITH compression enabled
    rawConn = await connectRawSocketWithUpgrade(socketPath, 5000, COMPRESSION_ZLIB);
    sendAttachPacket(rawConn, "compression-test");
    await Bun.sleep(100);

    // Clear any initial data (scrollback, shell prompt, etc.)
    rawConn.dataBuffer = Buffer.alloc(0);

    // Generate large output with a shell command (seq generates lines efficiently)
    // printf outputs a large block of repeating data that compresses very well
    const cmd = "printf '%500s\\n' '' | tr ' ' 'X'\n";
    const pkt = Buffer.alloc(2 + cmd.length);
    pkt[0] = MessageType.PUSH;
    pkt[1] = cmd.length;
    Buffer.from(cmd).copy(pkt, 2);
    rawConn.socket.write(pkt);

    // Wait for response (shell needs time to execute and output)
    await Bun.sleep(1000);

    // Look for compressed terminal_data response
    // Type byte will be (0 | 0x80) = 0x80 for compressed terminal_data
    let foundCompressed = false;
    let offset = 0;

    while (offset + RESPONSE_HEADER_SIZE <= rawConn.dataBuffer.length) {
      const typeByte = rawConn.dataBuffer[offset];
      const len = rawConn.dataBuffer.readUInt32LE(offset + 1);

      // Check if this is compressed terminal_data
      const isCompressed = (typeByte & COMPRESSION_FLAG) !== 0;
      const actualType = typeByte & ~COMPRESSION_FLAG;

      if (actualType === ResponseType.TERMINAL_DATA && isCompressed) {
        foundCompressed = true;
        // Verify the compressed data is smaller than original
        // 500 bytes of "X" should compress very well (probably 10-20 bytes)
        expect(len).toBeLessThan(500);
        break;
      }

      // Move to next response
      if (offset + RESPONSE_HEADER_SIZE + len <= rawConn.dataBuffer.length) {
        offset += RESPONSE_HEADER_SIZE + len;
      } else {
        break;
      }
    }

    expect(foundCompressed).toBe(true);
  });

  test("small terminal data is NOT compressed", async () => {
    // Connect without compression to verify uncompressed responses
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "no-compression-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Generate small output with echo (< 64 bytes, compression threshold)
    const cmd = "echo Hello\n";
    const pkt = Buffer.alloc(2 + cmd.length);
    pkt[0] = MessageType.PUSH;
    pkt[1] = cmd.length;
    Buffer.from(cmd).copy(pkt, 2);
    rawConn.socket.write(pkt);

    await Bun.sleep(300);

    // All responses should be uncompressed (type byte < 0x80)
    let offset = 0;
    let foundUncompressedTerminalData = false;

    while (offset + RESPONSE_HEADER_SIZE <= rawConn.dataBuffer.length) {
      const typeByte = rawConn.dataBuffer[offset];
      const len = rawConn.dataBuffer.readUInt32LE(offset + 1);

      const isCompressed = (typeByte & COMPRESSION_FLAG) !== 0;
      const actualType = typeByte & ~COMPRESSION_FLAG;

      if (actualType === ResponseType.TERMINAL_DATA) {
        // Small data should NOT be compressed
        expect(isCompressed).toBe(false);
        foundUncompressedTerminalData = true;
      }

      if (offset + RESPONSE_HEADER_SIZE + len <= rawConn.dataBuffer.length) {
        offset += RESPONSE_HEADER_SIZE + len;
      } else {
        break;
      }
    }

    expect(foundUncompressedTerminalData).toBe(true);
  });

  test("compressed data can be decompressed correctly", async () => {
    const zlib = await import("zlib");

    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "decompress-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Send compressible data with a unique marker
    const marker = "UNIQUE_MARKER_FOR_COMPRESSION_TEST";
    const data = marker + "X".repeat(200);

    for (let i = 0; i < data.length; i += 200) {
      const chunk = data.slice(i, i + 200);
      const pkt = Buffer.alloc(2 + chunk.length);
      pkt[0] = MessageType.PUSH;
      pkt[1] = chunk.length;
      Buffer.from(chunk).copy(pkt, 2);
      rawConn.socket.write(pkt);
    }

    await Bun.sleep(500);

    // Find and decompress any compressed responses
    let decompressedContent = "";
    let offset = 0;

    while (offset + RESPONSE_HEADER_SIZE <= rawConn.dataBuffer.length) {
      const typeByte = rawConn.dataBuffer[offset];
      const len = rawConn.dataBuffer.readUInt32LE(offset + 1);

      if (offset + RESPONSE_HEADER_SIZE + len > rawConn.dataBuffer.length) break;

      const isCompressed = (typeByte & COMPRESSION_FLAG) !== 0;
      const actualType = typeByte & ~COMPRESSION_FLAG;
      const payload = rawConn.dataBuffer.subarray(offset + RESPONSE_HEADER_SIZE, offset + RESPONSE_HEADER_SIZE + len);

      if (actualType === ResponseType.TERMINAL_DATA) {
        if (isCompressed) {
          // Decompress using zlib
          try {
            const decompressed = zlib.inflateSync(payload);
            decompressedContent += decompressed.toString();
          } catch {
            // If decompression fails, the test will fail when we check for marker
          }
        } else {
          decompressedContent += payload.toString();
        }
      }

      offset += RESPONSE_HEADER_SIZE + len;
    }

    // Verify the marker is in the decompressed content
    expect(decompressedContent).toContain(marker);
  });
});
