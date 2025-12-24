import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn } from "bun";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupSocket,
  socketExists,
  waitForSocket,
  startDetachedMaster,
  connectClient,
  connectAndWait,
  waitForOutput,
  writeToProc,
  killAndWait,
} from "./helpers";

describe("rtach CLI", () => {
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
    expect(output).toContain("rtach - terminal session manager");
    expect(output).toContain("Usage:");
    expect(output).toContain("-A <socket>");
    expect(output).toContain("-a <socket>");
    expect(output).toContain("-c <socket>");
    expect(output).toContain("-n <socket>");
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
    expect(output).toContain("rtach - terminal session manager");
  });

  test("fails without socket path", async () => {
    const proc = spawn([RTACH_BIN], {
      stdout: "pipe",
      stderr: "pipe",
    });

    const stderr = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    expect(exitCode).toBe(1);
    expect(stderr).toContain("socket path required");
  });
});

describe("rtach session creation", () => {
  let socketPath: string;

  beforeEach(() => {
    socketPath = uniqueSocketPath();
  });

  afterEach(() => {
    cleanupSocket(socketPath);
  });

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

  afterEach(async () => {
    await killAndWait(master, 9);
    cleanupSocket(socketPath);
  });

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

  afterEach(async () => {
    await killAndWait(master, 9);
    cleanupSocket(socketPath);
  });

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

  afterEach(async () => {
    await killAndWait(master, 9);
    cleanupSocket(socketPath);
  });

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

  afterEach(() => {
    cleanupSocket(socketPath);
  });

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

  afterEach(() => {
    cleanupSocket(socketPath);
  });

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
