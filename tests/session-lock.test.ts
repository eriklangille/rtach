import { describe, test, expect, afterEach } from "bun:test";
import { spawn } from "bun";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "fs";
import { connect } from "net";
import { tmpdir } from "os";
import { join } from "path";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupAll,
  startDetachedMaster,
  trackProcess,
} from "./helpers";

/**
 * One master per session
 *
 * `-A` decides under `<socket>.lock` whether a master answers on the socket, and
 * starts one only if none does, so concurrent `-A` don't start two. A master
 * removes its socket and FIFO on exit only if they're still its own, so a master
 * exiting late doesn't take the path from a newer one.
 */

describe("session lock", () => {
  let socketPath: string;
  let startsFile: string;
  let script: string;

  function setup(): void {
    socketPath = uniqueSocketPath();
    const id = Math.random().toString(36).substring(2, 10);
    startsFile = join(tmpdir(), `rtach-test-starts-${id}.txt`);
    script = join(tmpdir(), `rtach-test-prog-${id}.sh`);
    // Each master runs this once: it records the master's pid and its own
    writeFileSync(script, `#!/bin/sh\necho "$PPID $$" >> ${startsFile}\nwhile :; do sleep 0.2; done\n`);
    chmodSync(script, 0o755);
  }

  afterEach(async () => {
    await cleanupAll();
  });

  /** One line per started master: [master pid, program pid] */
  function starts(): number[][] {
    if (!existsSync(startsFile)) return [];
    return readFileSync(startsFile, "utf8").trim().split("\n").filter(Boolean).map((l) => l.split(" ").map(Number));
  }

  async function waitForStarts(count: number, timeoutMs = 3000): Promise<void> {
    const start = Date.now();
    while (starts().length < count && Date.now() - start < timeoutMs) await Bun.sleep(25);
  }

  async function waitForExit(pid: number, timeoutMs = 3000): Promise<void> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      try {
        process.kill(pid, 0);
      } catch {
        return;
      }
      await Bun.sleep(25);
    }
    throw new Error(`process ${pid} still running`);
  }

  function answers(path: string): Promise<boolean> {
    return new Promise((resolve) => {
      const socket = connect(path);
      socket.once("connect", () => {
        socket.destroy();
        resolve(true);
      });
      socket.once("error", () => resolve(false));
    });
  }

  function attachA(): ReturnType<typeof spawn> {
    return trackProcess(spawn([RTACH_BIN, "-A", socketPath, "-E", script], { stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
  }

  test("concurrent -A start one master", async () => {
    setup();
    const clients = Array.from({ length: 10 }, attachA);
    await waitForStarts(1);
    await Bun.sleep(500);

    expect(starts().length).toBe(1);
    expect(await answers(socketPath)).toBe(true);
    for (const c of clients) expect(c.exitCode).toBeNull();
  });

  test("-A replaces a socket nobody answers on", async () => {
    setup();
    await startDetachedMaster(socketPath, script);
    await waitForStarts(1);
    const [master] = starts()[0];
    process.kill(master, "SIGKILL");
    await waitForExit(master);
    expect(existsSync(socketPath)).toBe(true);

    const client = attachA();
    await waitForStarts(2);
    await Bun.sleep(200);
    expect(starts().length).toBe(2);
    expect(await answers(socketPath)).toBe(true);
    expect(client.exitCode).toBeNull();
  });

  test("a master exiting leaves a newer master's socket and FIFO", async () => {
    setup();
    await startDetachedMaster(socketPath, script);
    await waitForStarts(1);
    // A second master takes the path (-n doesn't check for a live one)
    await startDetachedMaster(socketPath, script);
    await waitForStarts(2);
    const [[first, firstProgram]] = starts();

    // The first master exits when its program does
    process.kill(firstProgram, "SIGKILL");
    await waitForExit(first);

    expect(existsSync(socketPath)).toBe(true);
    expect(existsSync(`${socketPath}.cmd`)).toBe(true);
    expect(await answers(socketPath)).toBe(true);
  });
});
