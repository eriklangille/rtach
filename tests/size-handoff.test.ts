import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn } from "bun";
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
  RTACH_BIN,
  trackProcess,
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
// Attach flag: loading the pane, not using it (protocol.zig)
const ATTACH_FLAG_BACKGROUND = 1 << 2;
// claim_active payload: for commands only, not the size
const CLAIM_FLAG_COMMANDS_ONLY = 1 << 0;
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

  /** A client attaching with ATTACH_FLAG_BACKGROUND: loading the pane, not using it */
  async function backgroundClient(id: string, size: { rows: number; cols: number }): Promise<RawRtachConnection> {
    const conn = await connectRawSocketWithUpgrade(socketPath);
    const payload = Buffer.alloc(17);
    Buffer.from(id).copy(payload, 0, 0, 16);
    payload[16] = ATTACH_FLAG_BACKGROUND;
    send(conn, MessageType.ATTACH, payload);
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

  test("the client in use gets its size, and keeps it when it pauses", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    watcher = a;
    const b = await client("bbbbbbbb-size-test", B);

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(b, MessageType.PUSH, Buffer.from(" ")))).toEqual([size(B)]);
    // b went to the background: a only shows the pane, so the size stays
    expect(await winches(() => send(b, MessageType.PAUSE))).toEqual([]);
    // until a is used
    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    a.close();
    b.close();
  });

  test("a pre-fetch (resume without a claim) doesn't take the size back", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    const b = await client("bbbbbbbb-size-test", B);
    watcher = b;

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(a, MessageType.PAUSE))).toEqual([]);
    // Every resume signals the program to repaint, at the size the PTY kept
    expect(await winches(() => send(a, MessageType.RESUME))).toEqual([size(A)]);
    expect(await winches(() => send(a, MessageType.PAUSE))).toEqual([]);
    // b is used: it takes the size, and a's pre-fetches don't take it back
    expect(await winches(() => send(b, MessageType.CLAIM_ACTIVE))).toEqual([size(B)]);
    expect(await winches(() => {
      send(a, MessageType.RESUME);
      send(a, MessageType.PAUSE);
    })).toEqual([size(B)]);
    // Showing the tab again: the app resumes, then claims
    const shown = await winches(() => {
      send(a, MessageType.RESUME);
      send(a, MessageType.CLAIM_ACTIVE);
    });
    expect(shown.at(-1)).toBe(size(A));
    a.close();
    b.close();
  });

  test("detaching or disconnecting leaves the size to the client left", async () => {
    const a = await client("aaaaaaaa-size-test", A);
    const b = await client("bbbbbbbb-size-test", B);
    watcher = a;

    expect(await winches(() => send(a, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(b, MessageType.CLAIM_ACTIVE))).toEqual([size(B)]);
    expect(await winches(() => send(b, MessageType.DETACH))).toEqual([size(A)]);

    // A plain attach (a terminal) is use: it takes the size right away
    let c!: RawRtachConnection;
    expect(await winches(async () => { c = await client("cccccccc-size-test", B); })).toEqual([size(B)]);
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
    // The phone pauses (the app in the background): still its own until the laptop is used
    send(phone, MessageType.PAUSE);
    expect(await sizesTold(phone)).toEqual([]);
    send(laptop, MessageType.CLAIM_ACTIVE);
    expect(await sizesTold(phone)).toEqual([size(B)]);

    // A client that didn't ask (older apps, the CLI) gets none
    expect(await sizesTold(laptop)).toEqual([]);
    phone.close();
    laptop.close();
  });
  test("a background attach leaves the size with the client in use", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    watcher = laptop;
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));

    // The phone loads the pane (launch, or its window coming on screen): no resize
    let phone!: RawRtachConnection;
    expect(await winches(async () => { phone = await backgroundClient("bbbbbbbb-size-test", B); })).toEqual([]);
    send(phone, MessageType.WANT_SIZE);
    expect(await sizesTold(phone)).toEqual([size(A)]);
    // It types: in use now
    expect(await winches(() => send(phone, MessageType.PUSH, Buffer.from(" ")))).toEqual([size(B)]);
    expect(await sizesTold(phone)).toEqual([`${size(B)} yours`]);
    // The laptop claims it back; the phone's pause doesn't change it
    expect(await winches(() => send(laptop, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    expect(await winches(() => send(phone, MessageType.PAUSE))).toEqual([]);
    laptop.close();
    phone.close();
  });

  test("a device only viewing the pane doesn't take it when the one using it switches away", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));
    // The phone is open, showing the pane in its overview
    const phone = await backgroundClient("bbbbbbbb-size-test", B);
    watcher = phone;
    send(phone, MessageType.WANT_SIZE);
    expect(await sizesTold(phone)).toEqual([size(A)]);

    // The laptop shows another pane: it pauses this one, and the size stays
    expect(await winches(() => send(laptop, MessageType.PAUSE))).toEqual([]);
    // Its background fetches (resume, then pause) don't move it either
    expect(await winches(() => {
      send(laptop, MessageType.RESUME);
      send(laptop, MessageType.PAUSE);
    })).toEqual([size(A)]);
    expect(await sizesTold(phone)).toEqual([]);
    // Once the laptop has let go of the pane, the phone is the only one showing it
    laptop.close();
    expect(await sizesTold(phone, 400)).toEqual([`${size(B)} yours`]);
    phone.close();
  });

  test("a background attach that's the only client gets its size", async () => {
    const phone = await backgroundClient("bbbbbbbb-size-test", B);
    send(phone, MessageType.WANT_SIZE);
    expect(await sizesTold(phone)).toEqual([`${size(B)} yours`]);
    phone.close();
  });
  test("a claim for commands only leaves the size with the client in use", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    watcher = laptop;
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));
    const phone = await backgroundClient("bbbbbbbb-size-test", B);

    // The phone came to the foreground on this pane, but nobody typed there
    expect(await winches(() => send(phone, MessageType.CLAIM_ACTIVE, Buffer.from([CLAIM_FLAG_COMMANDS_ONLY])))).toEqual([]);
    // A plain claim (Tap to use here) takes it
    expect(await winches(() => send(phone, MessageType.CLAIM_ACTIVE))).toEqual([size(B)]);
    laptop.close();
    phone.close();
  });

  test("the app's proxy attaches in the background and passes a claim's flags on", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    watcher = laptop;
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));

    // What the app runs over SSH; it writes framed packets to the proxy's stdin
    const proxy = trackProcess(spawn([RTACH_BIN, "--proxy", "--ready", "--background", "-a", socketPath], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    }));
    const write = (bytes: number[] | Buffer) => {
      proxy.stdin!.write(Buffer.from(bytes));
      proxy.stdin!.flush();
    };
    const sizePayload = Buffer.alloc(8);
    sizePayload.writeUInt16LE(B.rows, 0);
    sizePayload.writeUInt16LE(B.cols, 2);
    expect(await winches(async () => {
      await Bun.sleep(200);
      write([MessageType.UPGRADE, 0]);
      await Bun.sleep(50);
      write(Buffer.concat([Buffer.from([MessageType.WINCH, 8]), sizePayload]));
      write([MessageType.CLAIM_ACTIVE, 1, CLAIM_FLAG_COMMANDS_ONLY]);
    }, 600)).toEqual([]);
    expect(await winches(() => write([MessageType.CLAIM_ACTIVE, 0]))).toEqual([size(B)]);
    proxy.kill(9);
    await proxy.exited;
    laptop.close();
  });

  test("a terminal answering the program doesn't take the size", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    watcher = laptop;
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));
    const phone = await backgroundClient("bbbbbbbb-size-test", B);

    // The phone's terminal answers a cursor position query and reports focus
    expect(await winches(() => send(phone, MessageType.PUSH, Buffer.from("\x1b[12;5R\x1b[I")))).toEqual([]);
    // A key does take it
    expect(await winches(() => send(phone, MessageType.PUSH, Buffer.from("\x1b[A")))).toEqual([size(B)]);
    // And the laptop's answers don't take it back
    expect(await winches(() => send(laptop, MessageType.PUSH, Buffer.from("\x1b]11;rgb:2828/2c2c/3434\x07")))).toEqual([]);
    laptop.close();
    phone.close();
  });

  test("a device that used the pane earlier doesn't take it when the laptop switches away", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    const phone = await backgroundClient("bbbbbbbb-size-test", B);
    watcher = laptop;
    // The phone typed there, then the laptop took it back
    expect(await winches(() => send(phone, MessageType.PUSH, Buffer.from("x")))).toEqual([size(B)]);
    expect(await winches(() => send(laptop, MessageType.CLAIM_ACTIVE))).toEqual([size(A)]);
    // The laptop shows another pane; the phone still streams this one (and sees the program)
    watcher = phone;
    expect(await winches(() => send(laptop, MessageType.PAUSE))).toEqual([]);
    laptop.close();
    phone.close();
  });

  test("a claim before the client's size makes it the client in use", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    watcher = laptop;
    await winches(() => send(laptop, MessageType.CLAIM_ACTIVE));
    // The laptop's connection is replaced; the new one claims before its first winch
    const again = await connectRawSocketWithUpgrade(socketPath);
    const payload = Buffer.alloc(17);
    Buffer.from("aaaaaaaa-size-test").copy(payload, 0, 0, 16);
    payload[16] = ATTACH_FLAG_BACKGROUND;
    send(again, MessageType.ATTACH, payload);
    send(again, MessageType.WANT_SIZE);
    send(again, MessageType.CLAIM_ACTIVE);
    // Its own (after "not yours" for the want_size before the claim), so the app sends its size
    expect((await sizesTold(again)).at(-1)).toBe(`${size(A)} yours`);
    const later = { rows: 40, cols: 160 };
    winch(again, later);
    expect(await sizesTold(again)).toEqual([`${size(later)} yours`]);
    again.close();
  });

  test("the client in use stays the size's owner while it's switched away", async () => {
    const laptop = await client("aaaaaaaa-size-test", A);
    send(laptop, MessageType.CLAIM_ACTIVE);
    send(laptop, MessageType.WANT_SIZE);
    expect(await sizesTold(laptop)).toEqual([`${size(A)} yours`]);
    const phone = await backgroundClient("bbbbbbbb-size-test", B);
    // Switching away and back: still its own the whole time, so no pill
    send(laptop, MessageType.PAUSE);
    expect(await sizesTold(laptop)).toEqual([]);
    send(laptop, MessageType.RESUME);
    send(laptop, MessageType.CLAIM_ACTIVE);
    expect(await sizesTold(laptop)).toEqual([]);
    laptop.close();
    phone.close();
  });
});
