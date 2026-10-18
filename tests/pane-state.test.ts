import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * Pane state (<socket>.state)
 *
 * The master records the foreground process and its directory, and an agent's state
 * from `clauntty agent-state` (a `state;` line on the session's command pipe) or the
 * terminal title. On a change it writes <socket>.state and tells the app with
 * `pane;<id>;<json>`. Each test has its own HOME, so nothing reaches a real app.
 */

describe("pane state", () => {
  let home: string;
  let id: string;
  let sock: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
    // What the app deploys: the clauntty command is rtach under another name
    mkdirSync(join(home, ".clauntty/bin"));
    symlinkSync(RTACH_BIN, join(home, ".clauntty/bin/clauntty"));
    id = "5E55A000-0000-4000-8000-" + Math.random().toString(16).slice(2, 14).padEnd(12, "0");
    sock = join(home, ".clauntty/sessions", id);
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh" });

  function readState(): any {
    return existsSync(`${sock}.state`) ? JSON.parse(readFileSync(`${sock}.state`, "utf8")) : null;
  }

  async function waitForState(check: (s: any) => boolean, timeoutMs = 4000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const s = readState();
      if (s && check(s)) return s;
      await Bun.sleep(100);
    }
    return readState();
  }

  async function start() {
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: home, env: env() });
    const client = trackProcess(spawn([RTACH_BIN, "-a", sock, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await waitForOutput(client, "$ ", 3000);
    return client;
  }

  test("records the foreground program and its directory", async () => {
    const dir = join(home, "work");
    mkdirSync(dir);
    const client = await start();
    client.stdin.write(`cd ${dir} && sleep 5\n`);
    const s = await waitForState((s) => s.fg === "sleep");
    expect(s.fg).toBe("sleep");
    expect(s.cwd).toBe(dir);
    expect(s.agent).toBe("none");
  });

  test("agent-state hooks set the state, and the app hears about it", async () => {
    // Stand in for the app: the active pointer names a pipe we read
    const appFifo = join(home, "app.cmd");
    spawnSync(["mkfifo", appFifo]);
    writeFileSync(join(home, ".clauntty/active"), `${appFifo}\n`);
    // `cat` stops when a writer closes the pipe: read it again until the test ends
    const appLog = join(home, "app.log");
    spawn(["sh", "-c", `while :; do cat ${appFifo} >> ${appLog}; done`]);

    const client = await start();
    // What a Claude Code Notification hook runs (it gets the event as JSON on stdin). By
    // full path, as the hooks do: another clauntty can come first on PATH.
    client.stdin.write(`echo '{"message":"Claude needs your permission to use Bash"}' | ~/.clauntty/bin/clauntty agent-state blocked\n`);
    const s = await waitForState((s) => s.state === "blocked");
    expect(s.agent).toBe("claude");
    expect(s.note).toBe("Claude needs your permission to use Bash");

    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");
    expect((await waitForState((s) => s.state === "done")).note).toBeUndefined();

    await Bun.sleep(300);
    const lines = readFileSync(appLog, "utf8").split("\n").filter((l) => l.startsWith("pane;"));
    expect(lines.some((l) => l.startsWith(`pane;${id};`) && l.includes('"state":"blocked"'))).toBe(true);
  });

  test("outside an rtach session, agent-state does nothing", () => {
    const r = spawnSync([join(home, ".clauntty/bin/clauntty"), "agent-state", "working"], {
      env: { ...env(), RTACH_CMD_PIPE: "" },
      stdin: "ignore",
    });
    expect(r.exitCode).toBe(0);
  });
});
