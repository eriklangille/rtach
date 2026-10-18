import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * Workspaces (`rtach ws`)
 *
 * Panes are ordinary rtach sessions; workspaces group them into tabs with split
 * layouts, in ~/.clauntty/workspaces/<id>.json. Each test gets its own HOME (under
 * /tmp: socket paths are limited to 104 bytes on macOS).
 */

type Layout = string | { split: "h" | "v"; ratio: number; a: Layout; b: Layout };
type ListedWorkspace = {
  id: string;
  name: string;
  cwd: string;
  tabs: { id: string; name: string; layout: Layout; panes: { id: string; title: string | null }[] }[];
};

describe("rtach ws", () => {
  let home: string;
  let project: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    project = join(home, "project");
    mkdirSync(join(project, ".git"), { recursive: true });
    mkdirSync(join(project, "src"));
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  function env(extra: Record<string, string> = {}) {
    return { ...process.env, HOME: home, SHELL: "/bin/sh", ...extra };
  }

  function ws(args: string[], options: { cwd?: string; env?: Record<string, string> } = {}) {
    const result = spawnSync([RTACH_BIN, "ws", ...args], { cwd: options.cwd ?? home, env: env(options.env) });
    const stdout = result.stdout.toString();
    if (result.exitCode !== 0) throw new Error(`rtach ws ${args.join(" ")}: ${result.stderr.toString()}`);
    return stdout;
  }

  function wsJson(args: string[], options: { cwd?: string; env?: Record<string, string> } = {}) {
    return JSON.parse(ws(args, options));
  }

  function list(): ListedWorkspace[] {
    return wsJson(["list", "--json"]).workspaces;
  }

  function panesOf(layout: Layout): string[] {
    return typeof layout === "string" ? [layout] : [...panesOf(layout.a), ...panesOf(layout.b)];
  }

  function socket(pane: string) {
    return join(home, ".clauntty/sessions", pane);
  }

  async function waitFor(check: () => boolean, timeoutMs = 3000) {
    const start = Date.now();
    while (!check() && Date.now() - start < timeoutMs) await Bun.sleep(25);
    return check();
  }

  function attach(pane: string) {
    return trackProcess(
      spawn([RTACH_BIN, "-a", socket(pane), "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" })
    );
  }

  test("new starts a pane in the git root and records the workspace", async () => {
    const created = wsJson(["new"], { cwd: join(project, "src") });
    expect(existsSync(socket(created.pane))).toBe(true);

    const [w] = list();
    expect(w.id).toBe(created.workspace);
    expect(w.name).toBe("project");
    expect(w.cwd).toBe(project);
    expect(w.tabs).toHaveLength(1);
    expect(w.tabs[0].layout).toBe(created.pane);

    // The pane knows who it is and starts in the workspace's directory
    const client = attach(created.pane);
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write('echo "id=$RTACH_SESSION_ID dir=$(pwd) home=$HOME"\n');
    const output = await waitForOutput(client, `home=${home}`, 3000);
    // With the environment of whoever ran `ws new`
    expect(output).toContain(`id=${created.pane} dir=${project} home=${home}`);
  });

  // The app runs `rtach ws` over a plain SSH command: no TERM, or a placeholder
  // like login's "network" that terminfo doesn't know, and often no LANG
  for (const term of [undefined, "dumb", "network"]) {
    test(`a pane started with TERM=${term ?? "(unset)"} gets a usable TERM and a locale`, async () => {
      const bare: Record<string, string> = { ...env() };
      for (const key of ["TERM", "LANG", "LC_ALL", "LC_CTYPE"]) delete bare[key];
      if (term) bare.TERM = term;
      const result = spawnSync([RTACH_BIN, "ws", "new", "--cwd", project], { cwd: home, env: bare });
      const { pane } = JSON.parse(result.stdout.toString());

      const client = attach(pane);
      await waitForOutput(client, "$ ", 3000);
      client.stdin.write('echo "term=$TERM lang=$LANG"\n');
      // Not the echoed command line: its values are still $TERM and $LANG
      const output = await waitForOutput(client, /term=[^$]*lang=[^$]/, 3000);
      expect(output).toMatch(/term=xterm-256color lang=\S+UTF-8/);
    });
  }

  test("a pane started with a TERM terminfo knows keeps it", async () => {
    const result = spawnSync([RTACH_BIN, "ws", "new", "--cwd", project], { cwd: home, env: env({ TERM: "vt100" }) });
    const { pane } = JSON.parse(result.stdout.toString());
    const client = attach(pane);
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write('echo "term=$TERM"\n');
    expect(await waitForOutput(client, /term=[^$]/, 3000)).toContain("term=vt100");
  });

  test("split defaults to the current pane and builds the layout tree", () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { pane: b } = wsJson(["split"], { env: { RTACH_SESSION_ID: a } });
    const { pane: c } = wsJson(["split", b, "-v"]);

    const [w] = list();
    expect(w.tabs[0].layout).toEqual({ split: "h", ratio: 0.5, a, b: { split: "v", ratio: 0.5, a: b, b: c } });
    expect(w.tabs[0].panes.map((p) => p.id)).toEqual([a, b, c]);
  });

  test("close ends the pane; the last pane takes its tab and workspace along", async () => {
    const { workspace, pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { pane: b } = wsJson(["split", a]);

    wsJson(["close", a]);
    expect(list()[0].tabs[0].layout).toBe(b);
    expect(await waitFor(() => !existsSync(socket(a)))).toBe(true);

    wsJson(["close", b]);
    expect(list()).toEqual([]);
    expect(existsSync(join(home, ".clauntty/workspaces", `${workspace}.json`))).toBe(false);
  });

  test("a pane whose shell exits leaves its workspace", async () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { tab: t2, pane: b } = wsJson(["tab", "--name", "logs"], { env: { RTACH_SESSION_ID: a } });
    expect(list()[0].tabs.map((t) => t.name)).toEqual(["1", "logs"]);

    const client = attach(b);
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write("exit\n");
    expect(await waitFor(() => list()[0].tabs.length === 1)).toBe(true);
    expect(list()[0].tabs.find((t) => t.id === t2)).toBeUndefined();
  });

  test("list drops panes whose master is gone", async () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { pane: b } = wsJson(["split", a]);
    // A master killed outright can't update the file
    const masters = spawnSync(["pgrep", "-f", `rtach.*${b}`]).stdout.toString().trim().split("\n");
    for (const pid of masters) process.kill(Number(pid), "SIGKILL");
    await Bun.sleep(100);

    expect(list()[0].tabs[0].layout).toBe(a);
  });

  test("concurrent splits all land", async () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const splits = Array.from({ length: 8 }, () =>
      spawn([RTACH_BIN, "ws", "split", a], { cwd: home, env: env(), stdout: "pipe", stderr: "pipe" })
    );
    const codes = await Promise.all(splits.map((s) => s.exited));
    expect(codes.every((c) => c === 0)).toBe(true);

    expect(panesOf(list()[0].tabs[0].layout)).toHaveLength(9);
  });

  test("move and rename", () => {
    const { workspace, tab: t1, pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { tab: t2, pane: b } = wsJson(["tab", workspace]);
    const { pane: c } = wsJson(["split", b]);

    wsJson(["move", c, t1]);
    const [w] = list();
    expect(panesOf(w.tabs.find((t) => t.id === t1)!.layout)).toEqual([a, c]);
    expect(w.tabs.find((t) => t.id === t2)!.layout).toBe(b);

    wsJson(["rename", workspace, "renamed"]);
    wsJson(["rename", t2, "logs"]);
    const [after] = list();
    expect(after.name).toBe("renamed");
    expect(after.tabs.map((t) => t.name)).toEqual(["1", "logs"]);
  });

  test("errors say what's wrong", () => {
    const result = spawnSync([RTACH_BIN, "ws", "split"], { cwd: home, env: env() });
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("not inside an rtach session");
  });
});
