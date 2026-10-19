import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * The picker (`rtach` with no arguments, `clauntty` in a terminal)
 *
 * Shows the workspaces, tabs and panes the app shows, attaches the chosen pane, and
 * comes back when the client detaches. Runs in a PTY, with its own HOME under /tmp.
 */

describe("picker", () => {
  let home: string;
  let project: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    project = join(home, "project");
    mkdirSync(join(project, ".git"), { recursive: true });
    mkdirSync(join(home, ".clauntty/bin"), { recursive: true });
    symlinkSync(RTACH_BIN, join(home, ".clauntty/bin/clauntty"));
  });

  afterEach(async () => {
    for (const w of list()) ws(["end", w.id]);
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  function env(extra: Record<string, string> = {}) {
    return { ...process.env, HOME: home, SHELL: "/bin/sh", TERM: "xterm-256color", ...extra };
  }

  function ws(args: string[]) {
    const result = spawnSync([RTACH_BIN, "ws", ...args, "--quiet"], { cwd: project, env: env() });
    if (result.exitCode !== 0) throw new Error(`rtach ws ${args.join(" ")}: ${result.stderr.toString()}`);
    return result.stdout.toString() ? JSON.parse(result.stdout.toString()) : null;
  }

  function list(): { id: string; name: string; tabs: { panes: { id: string }[] }[] }[] {
    return ws(["list", "--json"]).workspaces;
  }

  function panes() {
    return list().flatMap((w) => w.tabs.flatMap((t) => t.panes.map((p) => p.id)));
  }

  // The picker in a PTY. `screen()` is the last frame drawn, without escapes.
  function picker(argv: string[] = [RTACH_BIN], extraEnv: Record<string, string> = {}) {
    let output = "";
    const decoder = new TextDecoder();
    const proc = trackProcess(
      spawn(argv, {
        cwd: project,
        env: env(extraEnv),
        terminal: { cols: 100, rows: 30, data: (_t, data) => void (output += decoder.decode(data, { stream: true })) },
      })
    );
    const plain = (text: string) => text.replace(/\x1b\[[0-9;?<>]*[a-zA-Z]|\x1b[>=]|\x1b\][^\x07]*\x07/g, "");
    const screen = () => plain(output.slice(output.lastIndexOf("\x1b[2J")));
    return {
      proc,
      write: (text: string) => proc.terminal!.write(text),
      screen,
      output: () => plain(output),
      /** Output from now on, for waiting on what comes next */
      since() {
        const start = output.length;
        return () => plain(output.slice(start));
      },
      async waitFor(match: string | RegExp, from: () => string = screen, timeoutMs = 3000) {
        const start = Date.now();
        const found = () => (typeof match === "string" ? from().includes(match) : match.test(from()));
        while (!found() && Date.now() - start < timeoutMs) await Bun.sleep(25);
        if (!found()) throw new Error(`timed out waiting for ${match}; screen:\n${from()}`);
        return from();
      },
    };
  }

  // Keys typed before the pane's prompt are dropped (the client's raw mode flushes them)
  async function attach(p: ReturnType<typeof picker>, key: string) {
    const after = p.since();
    p.write(key);
    await p.waitFor("$ ", after);
  }

  test("shows workspaces and panes, attaches one, and comes back on detach", async () => {
    const { pane: a } = ws(["new", "proj", "--cwd", project]);
    const { pane: b } = ws(["split", a]);
    // A session in no workspace
    const loose = spawnSync([RTACH_BIN, "-n", join(home, ".clauntty/sessions/loose-one"), "/bin/sh"], { env: env() });
    expect(loose.exitCode).toBe(0);

    const p = picker();
    // Shells are named by their folder, as in the app, once their masters have looked
    const screen = await p.waitFor(/· project[\s\S]*· project[\s\S]*Other sessions/);
    expect(screen).toContain("proj  ~/project");

    // The first pane is selected; the second is one down
    p.write("j");
    await Bun.sleep(100);
    await attach(p, "\r");
    p.write("echo id=$RTACH_SESSION_ID\r");
    await p.waitFor(`id=${b}`, p.output);

    // Ctrl+\ detaches back to the picker, which stays on that pane
    p.write("\x1c");
    await p.waitFor("enter attach");
    await attach(p, "\r");
    p.write("echo again=$RTACH_SESSION_ID\r");
    await p.waitFor(`again=${b}`, p.output);

    p.write("\x1c");
    await p.waitFor("enter attach");
    p.write("q");
    expect(await p.proc.exited).toBe(0);
  });

  test("n opens a pane next to the selected one; x closes one after asking", async () => {
    const { pane: a } = ws(["new", "proj", "--cwd", project]);
    const p = picker();
    await p.waitFor("proj");

    await attach(p, "n");
    p.write("echo new=$RTACH_SESSION_ID\r");
    const output = await p.waitFor(/new=[0-9A-F-]{36}/, p.output);
    const created = output.match(/new=([0-9A-F-]{36})/)![1];
    expect(created).not.toBe(a);
    // In the same workspace, where the phone shows it
    expect(list().length).toBe(1);
    expect(panes()).toEqual([a, created]);

    // Back on the new pane; close it
    p.write("\x1c");
    await p.waitFor("enter attach");
    p.write("x");
    await p.waitFor("It ends what's running there");
    p.write("n"); // not yet
    await Bun.sleep(200);
    expect(panes()).toEqual([a, created]);
    p.write("x");
    await p.waitFor("It ends what's running there");
    p.write("y");
    const start = Date.now();
    while (panes().length > 1 && Date.now() - start < 3000) await Bun.sleep(50);
    expect(panes()).toEqual([a]);
    p.write("q");
    expect(await p.proc.exited).toBe(0);
  });

  test("shows an agent's status", async () => {
    const { pane } = ws(["new", "proj", "--cwd", project]);
    const client = trackProcess(
      spawn([RTACH_BIN, "-a", join(home, ".clauntty/sessions", pane), "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" })
    );
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write("~/.clauntty/bin/clauntty agent-state working < /dev/null\n");

    const p = picker();
    // Until the agent names the conversation: "Claude"
    await p.waitFor("◐ Claude", p.screen, 5000);
    p.write("q");
    expect(await p.proc.exited).toBe(0);
  });

  test("won't attach the pane it runs in", async () => {
    const { pane } = ws(["new", "proj", "--cwd", project]);
    const p = picker([RTACH_BIN], { RTACH_SESSION_ID: pane });
    await p.waitFor("enter attach");
    p.write("\r");
    await p.waitFor("That's the pane you're in");
    p.write("q");
    expect(await p.proc.exited).toBe(0);
  });

  test("with nothing to show, starts a workspace here", async () => {
    const p = picker();
    await p.waitFor("$ ", p.output);
    p.write("echo first=$RTACH_SESSION_ID\r");
    await p.waitFor(/first=[0-9A-F-]{36}/, p.output);
    expect(list().map((w) => w.name)).toEqual(["project"]);
  });

  test("bare clauntty in a terminal is the picker; piped, it prints its usage", async () => {
    ws(["new", "proj", "--cwd", project]);
    const p = picker([join(home, ".clauntty/bin/clauntty")]);
    await p.waitFor("enter attach");
    p.write("q");
    expect(await p.proc.exited).toBe(0);

    const piped = spawnSync([join(home, ".clauntty/bin/clauntty")], { env: env() });
    expect(piped.exitCode).toBe(2);
    expect(piped.stdout.toString()).toContain("Usage");
  });
});
