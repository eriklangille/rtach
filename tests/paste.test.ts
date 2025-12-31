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

/**
 * Paste reliability tests
 *
 * These tests verify that large data (like multi-line paste) is reliably
 * transmitted through the PTY without data loss from short writes.
 *
 * The fix in master.zig 2.7.0 ensures that PTY writes loop until all bytes
 * are written, handling cases where the PTY buffer is full.
 */

describe("paste reliability", () => {
  let socketPath: string;
  let master: Awaited<ReturnType<typeof startDetachedMaster>>;
  let rawConn: RawRtachConnection | null = null;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    // Use a large scrollback so we can verify all data arrives
    master = await startDetachedMaster(socketPath, "/bin/cat", 256 * 1024);
  });

  afterEach(async () => {
    if (rawConn) {
      rawConn.close();
      rawConn = null;
    }
    await cleanupAll();
  });

  // Helper to send push packet and return data sent
  function sendPushPacket(conn: RawRtachConnection, data: string): void {
    const dataBytes = Buffer.from(data, "utf8");
    // Split into chunks of max 255 bytes (1-byte length field)
    for (let i = 0; i < dataBytes.length; i += 200) {
      const chunk = dataBytes.subarray(i, Math.min(i + 200, dataBytes.length));
      const packet = Buffer.alloc(2 + chunk.length);
      packet[0] = MessageType.PUSH;
      packet[1] = chunk.length;
      chunk.copy(packet, 2);
      conn.socket.write(packet);
    }
  }

  // Helper to wait for specific data in framed responses
  async function waitForFramedData(
    conn: RawRtachConnection,
    expectedContent: string,
    timeoutMs: number = 5000
  ): Promise<string> {
    const startTime = Date.now();
    let accumulated = "";

    while (Date.now() - startTime < timeoutMs) {
      // Parse any framed responses in the buffer
      while (conn.dataBuffer.length >= 5) {
        const type = conn.dataBuffer[0];
        const len = conn.dataBuffer.readUInt32LE(1);

        if (conn.dataBuffer.length < 5 + len) {
          // Incomplete frame, wait for more
          break;
        }

        // Complete frame available
        const frameData = conn.dataBuffer.subarray(5, 5 + len);
        conn.dataBuffer = conn.dataBuffer.subarray(5 + len);

        if (type === ResponseType.TERMINAL_DATA) {
          accumulated += frameData.toString();
          if (accumulated.includes(expectedContent)) {
            return accumulated;
          }
        }
        // Skip other frame types (idle, etc.)
      }

      await Bun.sleep(10);
    }

    throw new Error(`Timeout waiting for: ${expectedContent.substring(0, 50)}...\nGot: ${accumulated.substring(0, 200)}...`);
  }

  test("single line paste (baseline)", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-single-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0); // Clear initial scrollback

    const testData = "hello world single line test";
    sendPushPacket(rawConn, testData);

    const result = await waitForFramedData(rawConn, testData, 3000);
    expect(result).toContain(testData);
  });

  test("multi-line paste (500 bytes)", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-500-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Create multi-line content similar to code paste
    const lines: string[] = [];
    for (let i = 0; i < 10; i++) {
      lines.push(`line ${i}: some code content here ${i.toString(16)}`);
    }
    const testData = lines.join("\n");
    const marker = `MARKER_500_${Date.now()}`;
    const fullData = testData + "\n" + marker;

    sendPushPacket(rawConn, fullData);

    const result = await waitForFramedData(rawConn, marker, 5000);
    expect(result).toContain(marker);
    // Verify we got all lines
    for (const line of lines) {
      expect(result).toContain(line);
    }
  });

  test("large paste (2KB)", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-2k-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // 2KB of text should stress PTY buffering
    const lines: string[] = [];
    for (let i = 0; i < 50; i++) {
      lines.push(`line ${i.toString().padStart(3, "0")}: ${"X".repeat(30)} END`);
    }
    const marker = `MARKER_2K_${Date.now()}`;
    const fullData = lines.join("\n") + "\n" + marker;

    sendPushPacket(rawConn, fullData);

    const result = await waitForFramedData(rawConn, marker, 10000);
    expect(result).toContain(marker);
  });

  test("rapid successive pastes", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-rapid-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Send 10 pastes in rapid succession
    const markers: string[] = [];
    for (let i = 0; i < 10; i++) {
      const marker = `RAPID_${i}_${Date.now()}`;
      markers.push(marker);
      sendPushPacket(rawConn, marker + "\n");
    }

    // Final marker to confirm all received
    const finalMarker = `FINAL_RAPID_${Date.now()}`;
    sendPushPacket(rawConn, finalMarker);

    const result = await waitForFramedData(rawConn, finalMarker, 10000);
    expect(result).toContain(finalMarker);

    // All markers should be present
    for (const marker of markers) {
      expect(result).toContain(marker);
    }
  });

  test("paste with special characters (brackets, escapes)", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-special-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Paste content with brackets and special chars (like code)
    const testData = `function test() {
  const arr = [1, 2, 3];
  if (arr.length > 0) {
    return arr[0];
  }
  return null;
}`;
    const marker = `SPECIAL_END_${Date.now()}`;
    const fullData = testData + "\n" + marker;

    sendPushPacket(rawConn, fullData);

    const result = await waitForFramedData(rawConn, marker, 5000);
    expect(result).toContain(marker);
    expect(result).toContain("function test()");
    expect(result).toContain("[1, 2, 3]");
  });

  test("simulated bracketed paste mode (like multi-line terminal paste)", async () => {
    rawConn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(rawConn, "paste-bracketed-test");
    await Bun.sleep(100);
    rawConn.dataBuffer = Buffer.alloc(0);

    // Bracketed paste mode wrapping: ESC[200~ ... ESC[201~
    const bracketStart = "\x1b[200~";
    const bracketEnd = "\x1b[201~";
    const content = "line 1\nline 2\nline 3";
    const marker = `BRACKETED_${Date.now()}`;

    // Note: /bin/cat doesn't interpret bracketed paste, just echoes it
    const fullData = bracketStart + content + bracketEnd + marker;
    sendPushPacket(rawConn, fullData);

    const result = await waitForFramedData(rawConn, marker, 5000);
    expect(result).toContain(marker);
  });
});
