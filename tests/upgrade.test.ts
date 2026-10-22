import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * Live upgrade (src/upgrade.zig)
 *
 * `upgrade;<rtach>` on a session's command pipe makes its master exec that binary with
 * `--resume`: the same process keeps the PTY, the shell and (through a state file) the
 * scrollback, modes and pane state. Clients are dropped and reattach: a terminal client
 * by itself, getting only what the new master wrote since. `rtach upgrade` sends it to
 * every older master. Each test has its own HOME.
 */

describe("live upgrade", () => {
  let home: string;
  let id: string;
  let sock: string;
  let next: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
    id = "5E55A000-0000-4000-8000-" + Math.random().toString(16).slice(2, 14).padEnd(12, "0");
    sock = join(home, ".clauntty/sessions", id);
    // "The newer rtach": a copy, so the master can tell it from its own binary
    next = join(home, "rtach-next");
    copyFileSync(RTACH_BIN, next);
    chmodSync(next, 0o755);
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh" });

  function startMaster(path = sock) {
    spawnSync([RTACH_BIN, "-n", path, "/bin/sh"], { cwd: home, env: env() });
  }

  /** `prompt`: wait for the shell's prompt, from the replay (an empty scrollback has none) */
  async function attach(path = sock, prompt = true) {
    const client = trackProcess(spawn([RTACH_BIN, "-a", path, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    if (prompt) await waitForOutput(client, "$ ", 3000);
    else await Bun.sleep(300);
    return client;
  }

  /** The master's pid: started with `-n <socket>`, or resumed with `--resume <socket>` */
  function masterPid(path = sock): number {
    const out = spawnSync(["pgrep", "-f", `(-n|--resume) ${path} `]).stdout.toString().trim().split("\n")[0];
    return Number(out);
  }

  function command(pid: number): string {
    return spawnSync(["ps", "-o", "command=", "-p", String(pid)]).stdout.toString().trim();
  }

  function send(line: string, path = sock) {
    spawnSync(["sh", "-c", `printf '%s\\n' "$1" > "$2"`, "sh", line, `${path}.cmd`]);
  }

  async function until(check: () => boolean, timeoutMs = 4000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      if (check()) return true;
      await Bun.sleep(100);
    }
    return check();
  }

  const state = (path = sock) => (existsSync(`${path}.state`) ? JSON.parse(readFileSync(`${path}.state`, "utf8")) : null);

  test("a master upgrades in place: same process, shell and scrollback; its clients stay", async () => {
    startMaster();
    const before = await attach();
    before.stdin.write("echo shell=$$ marker-$((40+2))\n");
    const shown = await waitForOutput(before, "marker-42", 3000);
    const shell = shown.match(/shell=(\d+)/)![1];
    const pid = masterPid();

    send(`upgrade;${next}`);
    expect(await until(() => command(pid).includes("rtach-next --resume"))).toBe(true);
    expect(masterPid()).toBe(pid);
    // The client reattached by itself, and didn't get what it had again
    before.stdin.write("echo after-$((50+5))\n");
    const out = await waitForOutput(before, "after-55", 3000);
    expect(out.split("marker-42").length - 1).toBe(1);
    expect(before.exitCode).toBeNull();

    // A new client gets the scrollback from before, and the same shell
    const after = await attach();
    await waitForOutput(after, "marker-42", 3000);
    after.stdin.write("echo again-shell=$$\n");
    await waitForOutput(after, `again-shell=${shell}`, 3000);
    expect(await until(() => state()?.rtach !== undefined)).toBe(true);
    expect(existsSync(`${sock}.resume`)).toBe(false);
  });

  test("pane state and a command sent with the upgrade carry over", async () => {
    startMaster();
    await attach();
    // In one write: the state line is handled before the upgrade
    send(`upgrade;${next}\nstate;blocked;Allow Bash`);
    const pid = masterPid();
    expect(await until(() => command(pid).includes("--resume"))).toBe(true);
    expect(await until(() => state()?.state === "blocked")).toBe(true);
    expect(state().note).toBe("Allow Bash");
    expect(state().agent).toBe("claude");
  });

  test("when an agent finished carries over", async () => {
    startMaster();
    await attach();
    send("state;done;");
    expect(await until(() => state()?.state === "done")).toBe(true);
    const doneAt = state().done_at;
    expect(doneAt).toBeGreaterThan(0);
    const pid = masterPid();
    // The new master writes the state file again: read its, not the old one's
    rmSync(`${sock}.state`);
    send(`upgrade;${next}`);
    expect(await until(() => command(pid).includes("--resume"))).toBe(true);
    expect(await until(() => state() !== null)).toBe(true);
    expect(state().state).toBe("done");
    expect(state().done_at).toBe(doneAt);
  });

  test("keyboard modes carry over", async () => {
    startMaster();
    const before = await attach();
    // Set Claude Code's keyboard modes, then push them out of the replay
    before.stdin!.write("printf '\\033[>5u\\033[>4;2m'; yes filler | head -c 20000\r");
    before.stdin!.flush();
    await Bun.sleep(800);
    const pid = masterPid();
    send(`upgrade;${next}`);
    expect(await until(() => command(pid).includes("--resume"))).toBe(true);
    await Bun.sleep(300);

    // A new client gets them back from the new master
    const after = trackProcess(spawn([RTACH_BIN, "-a", sock, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    const out = await waitForOutput(after, "\x1b[>5u", 3000);
    expect(out).toContain("\x1b[>4;2m\x1b[>5u");
  });

  test("an upgrade that can't happen leaves the master as it was", async () => {
    startMaster();
    const client = await attach();
    const pid = masterPid();

    // Missing, then not executable: nothing changes, the client stays
    send(`upgrade;${join(home, "missing")}`);
    writeFileSync(join(home, "not-exec"), "x");
    send(`upgrade;${join(home, "not-exec")}`);
    await Bun.sleep(500);
    expect(command(pid)).not.toContain("--resume");
    client.stdin.write("echo still-$((2+3))\n");
    await waitForOutput(client, "still-5", 3000);

    // Executable but exec fails (no #! and not a binary): clients are dropped, the
    // master stays, and the session works
    writeFileSync(join(home, "bad-exec"), "\x00\x01garbage");
    chmodSync(join(home, "bad-exec"), 0o755);
    send(`upgrade;${join(home, "bad-exec")}`);
    await Bun.sleep(800);
    expect(masterPid()).toBe(pid);
    expect(command(pid)).not.toContain("--resume");
    expect(existsSync(`${sock}.resume`)).toBe(false);
    const again = await attach();
    again.stdin.write("echo works-$((3+4))\n");
    await waitForOutput(again, "works-7", 3000);
  });

  test("a state file the new rtach can't read costs the scrollback, not the session", async () => {
    startMaster();
    const before = await attach();
    before.stdin.write("echo old-$((5+5))\n");
    await waitForOutput(before, "old-10", 3000);
    const pid = masterPid();

    // Stands in for a newer rtach whose state file this one can't read
    const wrapper = join(home, "rtach-wrapper");
    writeFileSync(wrapper, `#!/bin/sh\necho '{"format":999}' > "$2.resume"\nexec ${next} "$@"\n`);
    chmodSync(wrapper, 0o755);
    send(`upgrade;${wrapper}`);
    expect(await until(() => command(pid).includes("rtach-next --resume"))).toBe(true);

    const after = await attach(sock, false);
    after.stdin.write("echo new-$((6+6))\n");
    const out = await waitForOutput(after, "new-12", 3000);
    expect(out).not.toContain("old-10");
  });

  test("rtach upgrade asks older masters, and skips current and too-old ones", async () => {
    // An older master (its state says so), a current one, one too old to upgrade
    const ids = ["A", "B", "C"].map((x) => id.slice(0, -1) + x);
    const socks = ids.map((x) => join(home, ".clauntty/sessions", x));
    for (const s of socks) startMaster(s);
    for (const s of socks) expect(await until(() => state(s)?.rtach !== undefined)).toBe(true);
    await Bun.sleep(1200); // past the first probes, so the masters don't rewrite it
    writeFileSync(`${socks[0]}.state`, JSON.stringify({ ...state(socks[0]), rtach: "2.18.0" }));
    const { rtach: _, ...withoutVersion } = state(socks[2]);
    writeFileSync(`${socks[2]}.state`, JSON.stringify(withoutVersion));
    const pids = socks.map((s) => masterPid(s));

    const r = spawnSync([next, "upgrade", "--json"], { env: env() });
    expect(JSON.parse(r.stdout.toString())).toEqual({ upgraded: 1, current: 1, too_old: 1, failed: 0 });
    expect(command(pids[0])).toContain("rtach-next --resume");
    expect(command(pids[1])).not.toContain("--resume");
    expect(command(pids[2])).not.toContain("--resume");
  });

  test("a client attached through an upgrade gets output from around it exactly once", async () => {
    startMaster();
    const client = await attach();
    client.stdin.write("for i in $(seq 1 40); do echo tick-$i; sleep 0.05; done; echo done-$((1+1))\n");
    await waitForOutput(client, "tick-5", 3000);
    const pid = masterPid();
    send(`upgrade;${next}`);
    expect(await until(() => command(pid).includes("--resume"))).toBe(true);

    const out = await waitForOutput(client, "done-2", 5000);
    for (let i = 1; i <= 40; i++) {
      expect(out.match(new RegExp(`tick-${i}\\r?\\n`, "g"))?.length ?? 0).toBe(1);
    }
  });

  test("a terminal client ends with its session, or a master that's gone without a word", async () => {
    // The shell exits: the master says `ended`, and the client doesn't reattach
    startMaster();
    const client = await attach();
    client.stdin.write("exit\n");
    expect(await until(() => client.exitCode !== null)).toBe(true);

    // Killed: no `ended`, and nothing answers on the socket when it tries
    const other = join(home, ".clauntty/sessions", id.slice(0, -1) + "K");
    startMaster(other);
    const orphan = await attach(other);
    process.kill(masterPid(other), "SIGKILL");
    expect(await until(() => orphan.exitCode !== null)).toBe(true);
  });
});

