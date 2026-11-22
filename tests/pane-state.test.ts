import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from "fs";
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

    expect(s.done_at).toBeUndefined();
    const before = Date.now();
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");
    const done = await waitForState((s) => s.state === "done");
    expect(done.note).toBeUndefined();
    // When it finished, for the app to tell a finish the user has seen
    expect(done.done_at).toBeGreaterThanOrEqual(before - 1000);
    expect(done.done_at).toBeLessThanOrEqual(Date.now() + 1000);

    await Bun.sleep(300);
    const lines = readFileSync(appLog, "utf8").split("\n").filter((l) => l.startsWith("pane;"));
    expect(lines.some((l) => l.startsWith(`pane;${id};`) && l.includes('"state":"blocked"'))).toBe(true);
  });

  test("the prompt hook gives the agent its task; a new session clears it", async () => {
    const client = await start();
    // What Claude Code's UserPromptSubmit hook gets on stdin
    writeFileSync(join(home, "prompt.json"), JSON.stringify({ prompt: "[Image #2] fix the keyboard flicker\nwhen switching" }));
    client.stdin.write("~/.clauntty/bin/clauntty agent-state working < ~/prompt.json\n");
    const s = await waitForState((s) => s.task !== undefined);
    expect(s.state).toBe("working");
    expect(s.task).toBe("fix the keyboard flicker");

    // A slash command keeps the task
    writeFileSync(join(home, "prompt.json"), JSON.stringify({ prompt: "/compact" }));
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < ~/prompt.json\n");
    expect((await waitForState((s) => s.state === "done")).task).toBe("fix the keyboard flicker");

    // SessionStart (a new session, or /clear)
    client.stdin.write("~/.clauntty/bin/clauntty agent-state idle < /dev/null\n");
    expect((await waitForState((s) => s.state === "idle")).task).toBeUndefined();
  });

  test("hooks give the agent's conversation id, for the app's chat view; the agent ending clears it", async () => {
    const client = await start();
    const sid = "7d3f2a9e-5b1c-4e8a-9f60-2c4d8e1b7a35";
    // Every Claude Code hook gets the session id on stdin
    writeFileSync(join(home, "start.json"), JSON.stringify({ session_id: sid, hook_event_name: "SessionStart" }));
    client.stdin.write("~/.clauntty/bin/clauntty agent-state idle < ~/start.json\n");
    const s = await waitForState((s) => s.agent_session !== undefined);
    expect(s.state).toBe("idle");
    expect(s.agent_session).toBe(sid);

    // Something that isn't an id never gets in (the app types it into a command)
    writeFileSync(join(home, "bad.json"), JSON.stringify({ session_id: "x; rm -rf ~", hook_event_name: "Stop" }));
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < ~/bad.json\n");
    expect((await waitForState((s) => s.state === "done")).agent_session).toBe(sid);

    client.stdin.write("~/.clauntty/bin/clauntty agent-state end < /dev/null\n");
    expect((await waitForState((s) => s.agent === "none")).agent_session).toBeUndefined();
  });

  test("Antigravity's hooks and title command print what agy reads back, in rtach or not", () => {
    const run = (state: string, input: object) =>
      spawnSync([join(home, ".clauntty/bin/clauntty"), "agent-state", "--agent", "antigravity", state], {
        env: { HOME: home, PATH: process.env.PATH ?? "" },
        stdin: Buffer.from(JSON.stringify(input)),
      }).stdout.toString();
    // PreToolUse must decide: "allow" goes on to agy's own rules
    expect(run("blocked", { hookEventName: "PreToolUse", toolCall: { name: "ask_question" } })).toBe('{"decision":"allow"}\n');
    expect(run("done", { hookEventName: "Stop", fullyIdle: true })).toBe("{}\n");
    // The title command's output is the window title
    expect(run("title", { agent_state: "working" })).toBe("Antigravity\n");
  });

  test("Antigravity's hooks and title set the state; agy leaving the foreground ends it", async () => {
    const client = await start();
    // A stand-in agy: anything named agy in front (rtach reads the process's name). Built,
    // not copied: macOS kills a copy of a system binary.
    spawnSync(["cc", "-x", "c", "-o", join(home, "agy"), "-"], {
      stdin: Buffer.from("#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(atoi(v[1])); return 0; }\n"),
    });
    const hook = (state: string, input: object) => {
      const file = join(home, `in-${Math.random().toString(16).slice(2)}.json`);
      writeFileSync(file, JSON.stringify(input));
      return `~/.clauntty/bin/clauntty agent-state --agent antigravity ${state} < ${file} > /dev/null`;
    };
    // Hooks in the background, as agy's run while it's in front
    const steps = [
      hook("working", { hookEventName: "PreInvocation", lastUserInput: "fix the build\nplease" }),
      "sleep 1.5",
      // An approval showing (its title command), then answered
      hook("title", { agent_state: "tool_use", tool_confirmation_pending: true }),
      "sleep 1.5",
      hook("title", { agent_state: "working" }),
      "sleep 1.5",
      // Its turn over, a background command still running: not done yet
      hook("done", { hookEventName: "Stop", fullyIdle: false }),
      "sleep 1.5",
      "touch ~/last",
      hook("done", { hookEventName: "Stop", fullyIdle: true }),
    ];
    client.stdin.write(`(sleep 1; ${steps.join("; ")}) & ~/agy 9\n`);

    // Every change, as it happens (the foreground is probed once a second)
    const seen: { state: string; agent: string; task?: string; fg: string; at: number }[] = [];
    const deadline = Date.now() + 12000;
    while (Date.now() < deadline && !seen.some((s) => s.state === "done")) {
      const s = readState();
      const last = seen[seen.length - 1];
      if (s && (!last || last.state !== s.state || last.fg !== s.fg)) seen.push({ ...s, at: Date.now() });
      await Bun.sleep(50);
    }
    const states = seen.filter((s) => s.agent === "antigravity").map((s) => s.state).filter((s, i, a) => s !== a[i - 1]);
    expect(states).toEqual(["working", "blocked", "working", "done"]);
    expect(seen.find((s) => s.state === "working")?.task).toBe("fix the build");
    expect(seen.some((s) => s.fg === "agy" && s.agent === "antigravity")).toBe(true);
    // Done only from the last Stop (fully idle), not the one before
    const lastHook = statSync(join(home, "last")).mtimeMs;
    expect(seen.find((s) => s.state === "done")!.at).toBeGreaterThanOrEqual(lastHook - 100);

    // agy gone, the shell in front: no agent
    const ended = await waitForState((s) => s.agent === "none", 9000);
    expect(ended.state).toBe("none");
    expect(ended.task).toBeUndefined();
  }, 20000);

  test("a title that isn't valid UTF-8 is still a string in the state and ws list", async () => {
    const client = await start();
    // A spinner character cut in half, then a stray byte
    client.stdin.write(`printf '\\033]0;\\342\\240 working \\377\\007'; sleep 5\n`);
    const s = await waitForState((s) => String(s.title ?? "").includes("working"));
    expect(s.title).toBe("?? working ?");
    spawnSync([RTACH_BIN, "ws", "add", id], { env: env() });
    const list = spawnSync([RTACH_BIN, "ws", "list", "--json"], { env: env() });
    const pane = JSON.parse(list.stdout.toString()).workspaces[0].tabs[0].panes[0];
    expect(pane.title).toBe("?? working ?");
  });

  test("outside an rtach session, agent-state does nothing", () => {
    const r = spawnSync([join(home, ".clauntty/bin/clauntty"), "agent-state", "working"], {
      env: { ...env(), RTACH_CMD_PIPE: "" },
      stdin: "ignore",
    });
    expect(r.exitCode).toBe(0);
  });
});
