import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, realpathSync, rmSync, utimesSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess } from "./helpers";

/**
 * `rtach sweep` (src/sweep.zig): clears what sessions whose master crashed or was
 * killed left in ~/.clauntty/sessions, keeping their logs for 7 days. Live sessions,
 * ones whose files changed in the last minute, and ones whose lock is held stay.
 */

describe("rtach sweep", () => {
  let home: string;
  let dir: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    dir = join(home, ".clauntty/sessions");
    mkdirSync(dir, { recursive: true });
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh" });
  const id = (n: number) => `5E55A000-0000-4000-8000-00000000000${n}`;

  /** A session whose master was killed: everything it had is still there */
  function crashed(n: number): string {
    const sock = join(dir, id(n));
    spawnSync([RTACH_BIN, "-A", sock, "-E", "/bin/sh"], { env: env(), stdin: "ignore", timeout: 500 });
    spawnSync(["pkill", "-9", "-f", `rtach.*${id(n)}`]);
    writeFileSync(`${sock}.state`, "{}");
    writeFileSync(`${sock}.title`, "t");
    return sock;
  }

  /** Make a session's files `age` seconds old */
  function age(sock: string, seconds: number, only?: string) {
    const when = Date.now() / 1000 - seconds;
    for (const f of readdirSync(dir).filter((f) => f.startsWith(only ?? sock.split("/").pop()!))) {
      utimesSync(join(dir, f), when, when);
    }
  }

  function sweep() {
    const r = spawnSync([RTACH_BIN, "sweep", "--json"], { env: env() });
    return JSON.parse(r.stdout.toString());
  }

  const files = (n: number) => readdirSync(dir).filter((f) => f.startsWith(id(n))).map((f) => f.slice(id(n).length) || "socket").sort();

  test("a killed session's files go after a quiet minute; its log after a week", () => {
    const sock = crashed(1);
    expect(files(1)).toEqual([".cmd", ".lock", ".log", ".state", ".title", "socket"]);

    // Just now: it might be starting
    expect(sweep()).toEqual({ sessions: 0, logs: 0 });
    expect(files(1).length).toBe(6);

    age(sock, 120);
    expect(sweep()).toEqual({ sessions: 1, logs: 0 });
    expect(files(1)).toEqual([".log"]);

    age(sock, 8 * 24 * 3600);
    expect(sweep()).toEqual({ sessions: 0, logs: 1 });
    expect(files(1)).toEqual([]);
  });

  test("a live session stays, however old its files", () => {
    const sock = join(dir, id(2));
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { env: env() });
    age(sock, 30 * 24 * 3600);
    expect(sweep()).toEqual({ sessions: 0, logs: 0 });
    expect(existsSync(sock)).toBe(true);
    expect(existsSync(`${sock}.log`)).toBe(true);
  });

  test("a session whose lock is held is being started: it stays", async () => {
    const sock = crashed(3);
    age(sock, 120);
    // Hold its lock, as `-A` does while it starts a master
    const holder = trackProcess(spawn(["python3", "-c", `import fcntl,time; f=open("${sock}.lock","a"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(10)`], { stdout: "pipe" }));
    const reader = holder.stdout.getReader();
    await reader.read();
    expect(sweep()).toEqual({ sessions: 0, logs: 0 });
    expect(files(3).length).toBe(6);
    holder.kill(9);
  });
});
