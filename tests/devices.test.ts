import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync } from "fs";
import { join } from "path";
import {
  RTACH_BIN,
  cleanupAll,
  trackSocket,
  connectRawSocketWithUpgrade,
  MessageType,
  ResponseType,
  type RawRtachConnection,
} from "./helpers";

/**
 * Every device hears about changes (active.devicePath, cli.notify)
 *
 * A Clauntty that claims a session gets a pointer of its own, ~/.clauntty/devices/<id>.
 * A workspace change or an agent's state goes to every device through its session,
 * addressed to it, not only to the one the single active pointer names. Showing a new
 * pane is for the device in use only; the others refresh.
 */

describe("devices", () => {
  let home: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh", RTACH_SPAWND_SOCKET: "" });

  function session(name: string): string {
    const sock = join(home, ".clauntty/sessions", name);
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: home, env: env() });
    trackSocket(sock);
    return sock;
  }

  function send(conn: RawRtachConnection, type: number, payload: Buffer = Buffer.alloc(0)) {
    const packet = Buffer.alloc(2 + payload.length);
    packet[0] = type;
    packet[1] = payload.length;
    payload.copy(packet, 2);
    conn.socket.write(packet);
  }

  /** A Clauntty with `id` (16 bytes) that attaches to `sock` and claims it */
  async function device(sock: string, id: string): Promise<RawRtachConnection> {
    const conn = await connectRawSocketWithUpgrade(sock);
    send(conn, MessageType.ATTACH, Buffer.from(id));
    send(conn, MessageType.CLAIM_ACTIVE);
    await Bun.sleep(100);
    return conn;
  }

  /** The commands a client got */
  function commands(conn: RawRtachConnection): string[] {
    const out: string[] = [];
    while (conn.dataBuffer.length >= 5) {
      const type = conn.dataBuffer[0];
      const len = conn.dataBuffer.readUInt32LE(1);
      if (conn.dataBuffer.length < 5 + len) break;
      if (type === ResponseType.COMMAND) out.push(conn.dataBuffer.subarray(5, 5 + len).toString());
      conn.dataBuffer = conn.dataBuffer.subarray(5 + len);
    }
    return out;
  }

  const hex = (id: string) => Buffer.from(id).toString("hex");
  const PHONE = "phone-0000000001";
  const LAPTOP = "laptop-000000001";

  test("a workspace change reaches every device; only the one in use shows the new pane", async () => {
    const a = session("A");
    const b = session("B");
    const laptop = await device(a, LAPTOP);
    // The phone claims last: the single pointer names its session
    const phone = await device(b, PHONE);
    expect(readdirSync(join(home, ".clauntty/devices")).sort()).toEqual([hex(LAPTOP), hex(PHONE)].sort());

    const created = JSON.parse(spawnSync([RTACH_BIN, "ws", "new", "x", "--cwd", home], { cwd: home, env: env() }).stdout.toString());
    await Bun.sleep(300);

    expect(commands(laptop).filter((c) => c.startsWith("workspace;"))).toEqual(["workspace;"]);
    const phoneGot = commands(phone).filter((c) => c.startsWith("workspace;"));
    expect(phoneGot).toContain(`workspace;${created.workspace}/${created.pane}`);
    laptop.close();
    phone.close();
  });

  test("a device's pointer goes when it leaves its session", async () => {
    const a = session("A");
    const laptop = await device(a, LAPTOP);
    const pointer = join(home, ".clauntty/devices", hex(LAPTOP));
    expect(existsSync(pointer)).toBe(true);
    laptop.close();
    await Bun.sleep(200);
    expect(existsSync(pointer)).toBe(false);
  });
});
