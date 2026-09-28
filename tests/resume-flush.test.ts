import { describe, test, expect, afterEach } from "bun:test";
import { inflateRawSync } from "zlib";
import { writeFileSync, chmodSync, rmSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import {
  uniqueSocketPath,
  cleanupAll,
  startDetachedMaster,
  connectRawSocketWithUpgrade,
  sendAttachPacket,
  MessageType,
  ResponseType,
  RESPONSE_HEADER_SIZE,
  COMPRESSION_FLAG,
  COMPRESSION_ZLIB,
  type RawRtachConnection,
} from "./helpers";

// Regression: resuming a paused client after lots of output flushed the buffered bytes as
// one large frame. Client sockets are non-blocking, the short writev was ignored, and the
// rest of the frame was dropped, so the client's framing desynced and compressed bytes
// were shown as terminal text.

const VALID_TYPES = new Set<number>(Object.values(ResponseType));

/// Parse every complete frame, strictly: an unknown type means the stream desynced.
function parseFrames(buffer: Buffer): { terminal: string; frames: number; maxFrame: number } {
  let offset = 0;
  let terminal = "";
  let frames = 0;
  let maxFrame = 0;
  while (offset + RESPONSE_HEADER_SIZE <= buffer.length) {
    const typeByte = buffer[offset];
    const actualType = typeByte & ~COMPRESSION_FLAG;
    if (!VALID_TYPES.has(actualType)) {
      throw new Error(`desync: invalid frame type 0x${typeByte.toString(16)} at offset ${offset}`);
    }
    const len = buffer.readUInt32LE(offset + 1);
    if (offset + RESPONSE_HEADER_SIZE + len > buffer.length) break;
    const payload = buffer.subarray(offset + RESPONSE_HEADER_SIZE, offset + RESPONSE_HEADER_SIZE + len);
    if (actualType === ResponseType.TERMINAL_DATA) {
      const data = (typeByte & COMPRESSION_FLAG) !== 0 ? inflateRawSync(payload) : payload;
      terminal += data.toString();
    }
    frames += 1;
    maxFrame = Math.max(maxFrame, len);
    offset += RESPONSE_HEADER_SIZE + len;
  }
  return { terminal, frames, maxFrame };
}

describe("rtach resume flush", () => {
  afterEach(cleanupAll);

  test("large output buffered while paused arrives intact on resume", async () => {
    // The session's own command produces the output (pushing it through cat's PTY input
    // can't go fast enough): wait, print ~310KB of varied lines, then idle.
    const marker = "END_OF_RESUME_FLUSH_MARKER";
    const script = join(tmpdir(), `rtach-resume-flush-${process.pid}.sh`);
    writeFileSync(
      script,
      `#!/bin/sh\nsleep 1.5\ni=0\nwhile [ $i -lt 6000 ]; do printf 'line %05d abcdefghijabcdefghijabcdefghij\\n' $i; i=$((i+1)); done\necho ${marker}\nsleep 60\n`,
    );
    chmodSync(script, 0o755);

    const socketPath = uniqueSocketPath();
    await startDetachedMaster(socketPath, script, 4 * 1024 * 1024);

    const client = await connectRawSocketWithUpgrade(socketPath, 5000, COMPRESSION_ZLIB);
    sendAttachPacket(client, "resume-flush");
    await Bun.sleep(100);
    client.socket.write(Buffer.from([MessageType.PAUSE, 0]));
    await Bun.sleep(100);
    const beforePause = client.dataBuffer.length;

    // Output happens while paused; no terminal data should arrive (idle frames may)
    await Bun.sleep(4000);
    expect(parseFrames(client.dataBuffer.subarray(beforePause)).terminal).toBe("");

    client.socket.write(Buffer.from([MessageType.RESUME, 0]));

    const deadline = Date.now() + 10000;
    let parsed = parseFrames(client.dataBuffer);
    while (!parsed.terminal.includes(marker) && Date.now() < deadline) {
      await Bun.sleep(100);
      parsed = parseFrames(client.dataBuffer);
    }

    expect(parsed.terminal).toContain("line 00000");
    expect(parsed.terminal).toContain("line 05999");
    expect(parsed.terminal).toContain(marker);
    // The flush is split into frames that fit the 32KB compression buffer
    expect(parsed.maxFrame).toBeLessThanOrEqual(32768);

    client.close();
    rmSync(script, { force: true });
  }, 30000);
});
