import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import {
  uniqueSocketPath,
  cleanupAll,
  startDetachedMaster,
  connectRawSocketWithUpgrade,
  sendAttachPacket,
  MessageType,
  ResponseType,
  type RawRtachConnection,
} from "./helpers";
import type { Subprocess } from "bun";

/**
 * Duplicate client kicking tests
 *
 * When a client connects with the same client_id as an existing connection,
 * the server should safely kick the old connection without crashing.
 *
 * This tests the fix for a use-after-free bug where destroying a kicked client
 * while its completion callback was still registered caused a SIGSEGV.
 */

describe("duplicate client handling", () => {
  let socketPath: string;
  let master: Subprocess;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    // Use /bin/cat as the command - it echoes input back
    master = await startDetachedMaster(socketPath, "/bin/cat");
  });

  afterEach(async () => {
    await cleanupAll();
  });

  // Helper to send a push packet
  function sendPushPacket(conn: RawRtachConnection, data: string): void {
    const dataBytes = Buffer.from(data, "utf8");
    const packet = Buffer.alloc(2 + dataBytes.length);
    packet[0] = MessageType.PUSH;
    packet[1] = dataBytes.length;
    dataBytes.copy(packet, 2);
    conn.socket.write(packet);
  }

  // Helper to wait for specific content in framed responses
  async function waitForFramedData(
    conn: RawRtachConnection,
    expectedContent: string,
    timeoutMs: number = 3000
  ): Promise<string> {
    const startTime = Date.now();
    let accumulated = "";

    while (Date.now() - startTime < timeoutMs) {
      // Parse any framed responses in the buffer
      while (conn.dataBuffer.length >= 5) {
        const type = conn.dataBuffer[0];
        const len = conn.dataBuffer.readUInt32LE(1);

        if (conn.dataBuffer.length < 5 + len) {
          break; // Incomplete frame
        }

        const frameData = conn.dataBuffer.subarray(5, 5 + len);
        conn.dataBuffer = conn.dataBuffer.subarray(5 + len);

        if (type === ResponseType.TERMINAL_DATA) {
          accumulated += frameData.toString();
          if (accumulated.includes(expectedContent)) {
            return accumulated;
          }
        }
      }
      await Bun.sleep(10);
    }

    throw new Error(`Timeout waiting for: "${expectedContent}"\nGot: "${accumulated}"`);
  }

  test("kicking duplicate client - new client can still communicate", async () => {
    // Connect first client with a specific client_id
    const conn1 = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(conn1, "test-client-id-12345678");
    await Bun.sleep(50);
    conn1.dataBuffer = Buffer.alloc(0); // Clear initial scrollback

    // Send some data from first client
    sendPushPacket(conn1, "from-client-1\n");
    await waitForFramedData(conn1, "from-client-1", 2000);

    // Connect second client with the SAME client_id
    // This should trigger the duplicate kick logic, kicking conn1
    const conn2 = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(conn2, "test-client-id-12345678");
    await Bun.sleep(100);
    conn2.dataBuffer = Buffer.alloc(0); // Clear scrollback

    // The key test: can conn2 still communicate with the server?
    // If the server crashed (SIGSEGV), this will fail with connection error
    sendPushPacket(conn2, "from-client-2\n");
    const result = await waitForFramedData(conn2, "from-client-2", 2000);
    expect(result).toContain("from-client-2");

    conn1.close();
    conn2.close();
  });

  test("rapid reconnections with same client_id - server remains responsive", async () => {
    const clientId = "rapid-reconnect-test-id";
    let lastConn: RawRtachConnection | null = null;

    // Rapidly connect/disconnect 5 times with same client_id
    for (let i = 0; i < 5; i++) {
      const conn = await connectRawSocketWithUpgrade(socketPath);
      sendAttachPacket(conn, clientId);
      await Bun.sleep(30);

      // Close previous connection after new one attaches (simulates takeover)
      if (lastConn) {
        lastConn.close();
      }
      lastConn = conn;
    }

    // Clear the buffer
    if (lastConn) {
      lastConn.dataBuffer = Buffer.alloc(0);

      // Verify the final connection can communicate
      sendPushPacket(lastConn, "after-rapid-reconnect\n");
      const result = await waitForFramedData(lastConn, "after-rapid-reconnect", 2000);
      expect(result).toContain("after-rapid-reconnect");

      lastConn.close();
    }
  });

  test("simultaneous duplicate connections - all are handled safely", async () => {
    const clientId = "simultaneous-test-id";
    const connections: RawRtachConnection[] = [];

    // Connect 3 clients rapidly with same ID
    for (let i = 0; i < 3; i++) {
      const conn = await connectRawSocketWithUpgrade(socketPath);
      connections.push(conn);
      sendAttachPacket(conn, clientId);
    }

    // Wait for the dust to settle
    await Bun.sleep(200);

    // At least one connection should work (the last one to attach, others got kicked)
    let workingConn: RawRtachConnection | null = null;
    for (const conn of connections) {
      try {
        conn.dataBuffer = Buffer.alloc(0);
        sendPushPacket(conn, "test-simultaneous\n");
        await waitForFramedData(conn, "test-simultaneous", 1000);
        workingConn = conn;
        break;
      } catch {
        // This connection was probably kicked, try the next one
      }
    }

    expect(workingConn).not.toBeNull();

    // Clean up
    for (const conn of connections) {
      conn.close();
    }
  });

  /**
   * CRASH REPRODUCTION TEST
   *
   * This replicates the exact crash scenario from production logs:
   * 1. Client A connects
   * 2. Client B connects with same client_id (triggers kick of A)
   * 3. Client B immediately disconnects
   * 4. Server crashes with SIGSEGV due to use-after-free in swapRemove
   *
   * The bug: When B disconnects, removeClient() calls swapRemove() which
   * reorders the array. If A's kicked callback fires after the reorder,
   * it has a stale index pointing to garbage memory.
   */
  test("CRASH REPRO: new client disconnects immediately after triggering kick", async () => {
    const clientId = "crash-repro-client-id";

    // Connect client A
    const connA = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(connA, clientId);
    await Bun.sleep(50);
    connA.dataBuffer = Buffer.alloc(0);

    // Verify A works
    sendPushPacket(connA, "from-A\n");
    await waitForFramedData(connA, "from-A", 2000);

    // Connect client B with same ID (triggers kick of A)
    const connB = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(connB, clientId);

    // KEY: Immediately disconnect B (don't wait for anything)
    // This should trigger the crash if the bug exists
    connB.close();

    // Small delay for callbacks to fire
    await Bun.sleep(100);

    // Verify server is still alive by connecting C
    const connC = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(connC, clientId);
    await Bun.sleep(50);
    connC.dataBuffer = Buffer.alloc(0);

    // If server crashed, this will fail with connection error
    sendPushPacket(connC, "from-C\n");
    const result = await waitForFramedData(connC, "from-C", 2000);
    expect(result).toContain("from-C");

    connA.close();
    connC.close();
  });

  /**
   * Stress test: rapid connect-kick-disconnect cycles
   */
  test("STRESS: rapid connect-kick-disconnect cycles", async () => {
    const clientId = "stress-test-id";

    for (let i = 0; i < 10; i++) {
      // Connect two clients with same ID in quick succession
      const conn1 = await connectRawSocketWithUpgrade(socketPath);
      sendAttachPacket(conn1, clientId);

      const conn2 = await connectRawSocketWithUpgrade(socketPath);
      sendAttachPacket(conn2, clientId);

      // Immediately close both (triggers the race)
      conn1.close();
      conn2.close();

      // Tiny delay between cycles
      await Bun.sleep(20);
    }

    // Server should still be alive
    await Bun.sleep(100);

    const connFinal = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(connFinal, "final-check");
    await Bun.sleep(50);
    connFinal.dataBuffer = Buffer.alloc(0);

    sendPushPacket(connFinal, "final-test\n");
    const result = await waitForFramedData(connFinal, "final-test", 2000);
    expect(result).toContain("final-test");

    connFinal.close();
  });
});
