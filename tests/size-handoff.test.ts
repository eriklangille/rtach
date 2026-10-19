import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { chmodSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  uniqueSocketPath,
  cleanupAll,
  startDetachedMaster,
  connectRawSocketWithUpgrade,
  sendAttachPacket,
  MessageType,
  ResponseType,
  HANDSHAKE_FLAG_PTY_SIZE,
  type RawRtachConnection,
} from "./helpers";

/**
 * Size handoff between clients
 *
 * Every client's size is kept, and the PTY takes the size of the client in use:
 * the latest claim or input among clients that aren't paused. When that client
 * pauses, detaches or disconnects, the next one's size applies right away, so a
 * desktop gets its size back when the phone goes to the background.
 */

// Prints the PTY size on every SIGWINCH
const WINCH_SCRIPT = `#!/bin/sh
trap 'echo "WINCH $(stty size)"' WINCH
while :; do sleep 0.05; done
`;

const A = { rows: 30, cols: 100 };
const B = { rows: 50, cols: 200 };

describe("size handoff", () => {
  let socketPath: string;
  let output = "";
  let watcher: RawRtachConnection;

  beforeEach(async () => {
    socketPath = uniqueSocketPath();
    const script = join(tmpdir(), `rtach-winch-${process.pid}-${Date.now()}.sh`);
    writeFileSync(script, WINCH_SCRIPT);
    chmodSync(script, 0o755);
    await startDetachedMaster(socketPath, script);
    await Bun.sleep(100);
  });

  afterEach(async () => {
    await cleanupAll();
  });

  function send(conn: RawRtachConnection, type: number, payload: Buffer = Buffer.alloc(0)): void {
    const packet = Buffer.alloc(2 + payload.length);
    packet[0] = type;
    packet[1] = payload.length;
    payload.copy(packet, 2);
    conn.socket.write(packet);
  }

  function winch(conn: RawRtachConnection, size: { rows: number; cols: number }): void {
    const payload = Buffer.alloc(8);
    payload.writeUInt16LE(size.rows, 0);
    payload.writeUInt16LE(size.cols, 2);
    send(conn, MessageType.WINCH, payload);
  }

  async function client(id: string, size: { rows: number; cols: number }): Promise<RawRtachConnection> {
    const conn = await connectRawSocketWithUpgrade(socketPath);
    sendAttachPacket(conn, id);
    winch(conn, size);
    await Bun.sleep(50);
    return conn;
  }

  /** Terminal output a client received since the last call (pty_size frames go to `told`) */
  function drain(conn: RawRtachConnection): string {
    let text = "";
    while (conn.dataBuffer.length >= 5) {
      const type = conn.dataBuffer[0];
      const len = conn.dataBuffer.readUInt32LE(1);
      if (conn.dataBuffer.length < 5 + len) break;
      const payload = conn.dataBuffer.subarray(5, 5 + len);
      if (type === ResponseType.TERMINAL_DATA) {
        text += payload.toString();
      } else if (type === ResponseType.PTY_SIZE) {
        const yours = (payload[4] & 1) !== 0;
        told.set(conn, [...(told.get(conn) ?? []), `${payload.readUInt16LE(0)}x${payload.readUInt16LE(2)}${yours ? " yours" : ""}`]);
      }
      conn.dataBuffer = conn.dataBuffer.subarray(5 + len);
    }
    return text;
  }

  /** The pty_size frames each client got */
  const told = new Map<RawRtachConnection, string[]>();

  /** pty_size frames a client got since the last call */
  async function sizesTold(conn: RawRtachConnection, waitMs = 200): Promise<string[]> {
    await Bun.sleep(waitMs);
    drain(conn);
    const sizes = told.get(conn) ?? [];
    told.set(conn, []);
    return sizes;
  }

  /** The WINCH lines the program printed after an action, read through `watcher` */
  async function winches(action: () => void, waitMs = 400): Promise<string[]> {
    output += drain(watcher);
    output = "";
    action();
    await Bun.sleep(waitMs);
    output += drain(watcher);
    // One resize can print twice: the kernel signals on TIOCSWINSZ, and rtach does too
    const sizes = [...output.matchAll(/WINCH (\d+) (\d+)/g)].map((m) => `${m[1]}x${m[2]}`);
    return sizes.filter((s, i) => s !== sizes[i - 1]);
  }

  const size = (s: { rows: number; cols: number }) => `${s.rows}x${s.cols}`;

  test("the client in use gets its size, and gives it back when it pauses", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    watcher = a;
    const b = await client("bbbbbbbb-size-test", B);

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(b, MessageType.PUSH, Buffer.from(" ")))).toEqual([size(B)]);
    expect(await winches(() => send(b, MessageType.PAUSE))).toEqual([size(A)]);
    a.close();
    b.close();
  });

  test("a pre-fetch (resume without a claim) doesn't take the size back", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    const b = await client("bbbbbbbb-size-test", B);
    watcher = b;

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(a, MessageType.PAUSE))).toEqual([size(B)]);
    // Every resume signals the program to repaint, here at B's size, which stays
    expect(await winches(() => send(a, MessageType.RESUME))).toEqual([size(B)]);
    expect(await winches(() => send(a, MessageType.PAUSE))).toEqual([]);
    // Showing the tab again: the app resumes, then claims
    const shown = await winches(() => {
      send(a, MessageType.RESUME);
      send(a, MessageType.CLAIM_ACTIVE);
    });
    expect(shown.at(-1)).toBe(size(A));
    a.close();
    b.close();
  });

  test("detaching or disconnecting hands the size to the other client", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    const b = await client("bbbbbbbb-size-test", B);
    watcher = a;

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(b, MessageType.CLAIM_ACTIVE))).toEqual([size(B)]);
    expect(await winches(() => send(b, MessageType.DETACH))).toEqual([size(A)]);

    const c = await client("cccccccc-size-test", B);
    expect(await winches(() => send(c, MessageType.CLAIM_ACTIVE))).toEqual([size(B)]);
    expect(await winches(() => c.close())).toEqual([size(A)]);
    a.close();
    b.close();
  });

  test("a lone client that pauses keeps its size", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    watcher = a;
    await winches(() => send(a, MessageType.CLAIM_ACTIVE));

    expect(await winches(() => send(a, MessageType.PAUSE))).toEqual([]);
    // The resume repaint, at the size the PTY kept
    expect(await winches(() => send(a, MessageType.RESUME))).toEqual([size(A)]);
    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([]);
    a.close();
  });

  test("a size from a client not in use is kept for later, not applied", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    watcher = a;
    const b = await client("bbbbbbbb-size-test", B);
    await winches(() => send(a, MessageType.CLAIM_ACTIVE));

    const later = { rows: 40, cols: 160 };
    expect(await winches(() => winch(b, later))).toEqual([]);
    expect(await winches(() => send(b, MessageType.CLAIM_ACTIVE))).toEqual([size(later)]);
    a.close();
    b.close();
  });

  test("a client that asks is told the PTY's size and whether it's its own", async () => {
    const phone = await client("aaaaaaaa-size-test", A);
    const laptop = await client("bbbbbbbb-size-test", B);
    send(phone, MessageType.CLAIM_ACTIVE);
    await sizesTold(phone);

    // The handshake says the master answers want_size
    expect(phone.handshakeFlags! & HANDSHAKE_FLAG_PTY_SIZE).toBe(HANDSHAKE_FLAG_PTY_SIZE);

    // Right away, then on every change
    send(phone, MessageType.WANT_SIZE);
    expect(await sizesTold(phone)).toEqual([`${size(A)} yours`]);
    send(laptop, MessageType.PUSH, Buffer.from(" "));
    expect(await sizesTold(phone)).toEqual([size(B)]);
    // Same size, but now the phone's: still worth telling
    winch(phone, B);
    send(phone, MessageType.CLAIM_ACTIVE);
    expect(await sizesTold(phone)).toEqual([`${size(B)} yours`]);
    // Nothing changed: nothing sent
    send(phone, MessageType.CLAIM_ACTIVE);
    expect(await sizesTold(phone)).toEqual([]);
    // The phone pauses (the app in the background): the laptop's size, not the phone's
    send(phone, MessageType.PAUSE);
    expect(await sizesTold(phone)).toEqual([size(B)]);

    // A client that didn't ask (older apps, the CLI) gets none
    expect(await sizesTold(laptop)).toEqual([]);
    phone.close();
    laptop.close();
  });
});
