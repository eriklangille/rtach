import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawnSync } from "bun";
import { chmodSync, copyFileSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import {
  RTACH_BIN,
  cleanupAll,
  connectRawSocketWithUpgrade,
  sendAttachPacket,
  MessageType,
  ResponseType,
  RESPONSE_HEADER_SIZE,
  type RawRtachConnection,
} from "./helpers";

/**
 * A session that ends sends `ended` (a command frame) to every framed client before
 * closing them, so the app ends the window instead of reconnecting to find nothing.
 * A live upgrade, which also drops clients, doesn't.
 */

describe("ended", () => {
  let dir: string;
  let sock: string;

  beforeEach(() => {
    dir = realpathSync(mkdtempSync("/tmp/rtach-test-"));
    sock = join(dir, "s");
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(dir, { recursive: true, force: true });
  });

  function startMaster() {
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: dir, env: { ...process.env, SHELL: "/bin/sh" } });
  }

  /** An app-like client: framed, attached; `claim` like the window the user is on */
  async function client(name: string, claim: boolean): Promise<RawRtachConnection & { closed: Promise<void> }> {
    const conn = await connectRawSocketWithUpgrade(sock);
    const closed = new Promise<void>((resolve) => conn.socket.on("close", () => resolve()));
    sendAttachPacket(conn, name);
    if (claim) conn.socket.write(Buffer.from([MessageType.CLAIM_ACTIVE, 0]));
    await Bun.sleep(150);
    return Object.assign(conn, { closed });
  }

  /** The command frames a client got */
  function commands(conn: RawRtachConnection): string[] {
    const found: string[] = [];
    let buf = conn.dataBuffer;
    while (buf.length >= RESPONSE_HEADER_SIZE) {
      const len = buf.readUInt32LE(1);
      if (buf.length < RESPONSE_HEADER_SIZE + len) break;
      if (buf[0] === ResponseType.COMMAND) found.push(buf.subarray(5, 5 + len).toString());
      buf = buf.subarray(RESPONSE_HEADER_SIZE + len);
    }
    return found;
  }

  async function closedWithin(conn: { closed: Promise<void> }, ms = 3000) {
    return Promise.race([conn.closed.then(() => true), Bun.sleep(ms).then(() => false)]);
  }

  test("the shell exiting tells every client, the one in use and the others", async () => {
    startMaster();
    const shown = await client("shown", true);
    const other = await client("other", false);
    const input = Buffer.from("exit\n");
    shown.socket.write(Buffer.concat([Buffer.from([MessageType.PUSH, input.length]), input]));

    expect(await closedWithin(shown)).toBe(true);
    expect(await closedWithin(other)).toBe(true);
    expect(commands(shown)).toContain("ended");
    expect(commands(other)).toContain("ended");
  });

  test("a master told to stop says so too", async () => {
    startMaster();
    const shown = await client("shown", true);
    spawnSync(["pkill", "-TERM", "-f", `rtach -n ${sock} `]);

    expect(await closedWithin(shown)).toBe(true);
    expect(commands(shown)).toContain("ended");
  });

  test("a live upgrade drops clients without it", async () => {
    startMaster();
    const shown = await client("shown", true);
    // A copy, so the master can tell it from its own binary
    const next = join(dir, "rtach-next");
    copyFileSync(RTACH_BIN, next);
    chmodSync(next, 0o755);
    writeFileSync(`${sock}.cmd`, `upgrade;${next}\n`);

    expect(await closedWithin(shown)).toBe(true);
    expect(commands(shown)).not.toContain("ended");
  });
});
