import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { chmodSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  uniqueSocketPath,
  cleanupAll,
  startDetachedMaster,
  connectRawSocketWithUpgrade,
  MessageType,
  ResponseType,
  type RawRtachConnection,
} from "./helpers";

/**
 * `ready` after an attach (ATTACH_FLAG_READY, rtach --proxy --ready)
 *
 * A shell's screen is ready after the replay. A program on the alternate screen gets
 * no replay and only redraws on a real size change, so the master nudges: the PTY one
 * row short until the program has drawn for that, then back, and `ready`. The client
 * doesn't get the short redraw; after `ready` comes the redraw at the real size.
 */

const READY = 8;
const ATTACH_FLAG_READY = 1 << 1;
const HANDSHAKE_FLAG_READY = 1 << 2;
const READY_FLAG_NO_REDRAW = 1 << 0;

// On the alternate screen, prints its size on every SIGWINCH
const TUI = `#!/bin/sh
printf '\\033[?1049h'
trap 'echo "REDRAW $(stty size)"' WINCH
while :; do sleep 0.02; done
`;
// On the alternate screen, never redraws; prints its size when sent a line
const STUBBORN = `#!/bin/sh
printf '\\033[?1049h'
trap '' WINCH
while read -r _; do echo "SIZE $(stty size)"; done
`;
// Normal screen
const SHELLISH = `#!/bin/sh
echo "line one"
echo "line two"
trap 'echo "REDRAW $(stty size)"' WINCH
while :; do sleep 0.02; done
`;

const S = { rows: 30, cols: 100 };
const OTHER = { rows: 40, cols: 120 };

describe("ready", () => {
  let socketPath: string;

  async function start(script: string) {
    socketPath = uniqueSocketPath();
    const path = join(tmpdir(), `rtach-ready-${process.pid}-${Date.now()}.sh`);
    writeFileSync(path, script);
    chmodSync(path, 0o755);
    await startDetachedMaster(socketPath, path);
    await Bun.sleep(150);
  }

  afterEach(async () => {
    await cleanupAll();
  });

  function send(conn: RawRtachConnection, type: number, payload: Buffer = Buffer.alloc(0)) {
    const packet = Buffer.alloc(2 + payload.length);
    packet[0] = type;
    packet[1] = payload.length;
    payload.copy(packet, 2);
    conn.socket.write(packet);
  }

  function winch(conn: RawRtachConnection, size: { rows: number; cols: number }) {
    const payload = Buffer.alloc(8);
    payload.writeUInt16LE(size.rows, 0);
    payload.writeUInt16LE(size.cols, 2);
    send(conn, MessageType.WINCH, payload);
  }

  async function client(id: string, size: { rows: number; cols: number }, ready: boolean) {
    const conn = await connectRawSocketWithUpgrade(socketPath);
    const payload = Buffer.alloc(ready ? 17 : 16);
    Buffer.from(id.padEnd(16, "-").slice(0, 16)).copy(payload);
    if (ready) payload[16] = ATTACH_FLAG_READY;
    send(conn, MessageType.ATTACH, payload);
    winch(conn, size);
    return conn;
  }

  /** What a client got, in order: terminal text and "<ready>" where it came ("<ready
   * no-redraw NAME>" when the program didn't draw for the nudge) */
  function events(conn: RawRtachConnection): string[] {
    const out: string[] = [];
    while (conn.dataBuffer.length >= 5) {
      const type = conn.dataBuffer[0];
      const len = conn.dataBuffer.readUInt32LE(1);
      if (conn.dataBuffer.length < 5 + len) break;
      const payload = conn.dataBuffer.subarray(5, 5 + len);
      if (type === ResponseType.TERMINAL_DATA) out.push(payload.toString());
      else if (type === READY && len > 0 && (payload[0] & READY_FLAG_NO_REDRAW) !== 0)
        out.push(`<ready no-redraw ${payload.subarray(1).toString()}>`);
      else if (type === READY) out.push("<ready>");
      conn.dataBuffer = conn.dataBuffer.subarray(5 + len);
    }
    return out;
  }

  const redraws = (text: string) => [...text.matchAll(/REDRAW (\d+) (\d+)/g)].map((m) => `${m[1]}x${m[2]}`);

  test("the handshake says ready is there", async () => {
    await start(TUI);
    const conn = await connectRawSocketWithUpgrade(socketPath);
    expect(((conn.handshakeFlags ?? 0) & HANDSHAKE_FLAG_READY) !== 0).toBe(true);
    conn.close();
  });

  test("a program on the alternate screen is nudged: ready, then its redraw at the real size", async () => {
    await start(TUI);
    // Someone has the session at S already: attaching at S changes nothing
    const watcher = await client("watcher", S, false);
    send(watcher, MessageType.CLAIM_ACTIVE);
    await Bun.sleep(200);
    events(watcher);

    const c = await client("ready-client", S, true);
    await Bun.sleep(500);
    const got = events(c);
    const at = got.indexOf("<ready>");
    expect(at).toBeGreaterThan(-1);
    // Before: the switch to the alternate screen, but not the short redraw
    expect(got.slice(0, at).join("")).toContain("\x1b[?1049h");
    expect(redraws(got.slice(0, at).join(""))).toEqual([]);
    // After: the redraw at the real size
    expect(redraws(got.slice(at + 1).join(""))).toContain(`${S.rows}x${S.cols}`);
    // The program saw the short size, then the real one
    expect(redraws(events(watcher).join(""))).toEqual([`${S.rows - 1}x${S.cols}`, `${S.rows}x${S.cols}`]);
    c.close();
    watcher.close();
  });

  test("an attach that changes the size needs no nudge", async () => {
    await start(TUI);
    const watcher = await client("watcher", S, false);
    send(watcher, MessageType.CLAIM_ACTIVE);
    await Bun.sleep(200);
    events(watcher);

    const c = await client("ready-client", OTHER, true);
    send(c, MessageType.CLAIM_ACTIVE);
    await Bun.sleep(500);
    const got = events(c);
    const at = got.indexOf("<ready>");
    expect(at).toBeGreaterThan(-1);
    expect(redraws(got.slice(at + 1).join(""))).toContain(`${OTHER.rows}x${OTHER.cols}`);
    expect(redraws(events(watcher).join(""))).not.toContain(`${S.rows - 1}x${S.cols}`);
    c.close();
    watcher.close();
  });

  test("a program that doesn't redraw still gets ready, and its size back", async () => {
    await start(STUBBORN);
    const watcher = await client("watcher", S, false);
    send(watcher, MessageType.CLAIM_ACTIVE);
    await Bun.sleep(200);

    const c = await client("ready-client", S, true);
    await Bun.sleep(1300);
    // It says the program didn't draw, and which program
    // (the shell running the script: bash or sh)
    expect(events(c)).toContainEqual(expect.stringMatching(/^<ready no-redraw (ba)?sh>$/));
    // The nudge gave up and put the size back
    send(watcher, MessageType.PUSH, Buffer.from("\n"));
    await Bun.sleep(300);
    expect(events(watcher).join("")).toContain(`SIZE ${S.rows} ${S.cols}`);
    c.close();
    watcher.close();
  });

  test("a shell is ready right after the replay", async () => {
    await start(SHELLISH);
    const c = await client("ready-client", S, true);
    await Bun.sleep(300);
    const got = events(c);
    const at = got.indexOf("<ready>");
    expect(at).toBeGreaterThan(-1);
    expect(got.slice(0, at).join("")).toContain("line two");
    c.close();
  });

  test("a client that didn't ask gets no ready", async () => {
    await start(TUI);
    const c = await client("plain-client", S, false);
    await Bun.sleep(400);
    expect(events(c)).not.toContain("<ready>");
    c.close();
  });
});
