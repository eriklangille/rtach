import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync } from "fs";
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
  tabs: { id: string; name: string; layout: Layout; panes: { id: string; title: string | null; state: any }[] }[];
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

  test("a workspace in the home folder is named ~", () => {
    wsJson(["new", "--cwd", home]);
    expect(list()[0].name).toBe("~");
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

  test("split starts in the pane's directory; list has each pane's state", async () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const client = attach(a);
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write(`cd ${join(project, "src")} && sleep 3\n`);
    expect(await waitFor(() => list()[0].tabs[0].panes[0].state?.fg === "sleep")).toBe(true);
    expect(list()[0].tabs[0].panes[0].state.cwd).toBe(join(project, "src"));

    const { pane: b } = wsJson(["split", a]);
    const other = attach(b);
    await waitForOutput(other, "$ ", 3000);
    other.stdin.write('echo "dir=$(pwd)"\n');
    expect(await waitForOutput(other, /dir=\//, 3000)).toContain(`dir=${join(project, "src")}`);
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

  test("changes tell the app; --quiet doesn't", async () => {
    // Stand in for the app: the active pointer names a pipe we read
    const fifo = join(home, "app.cmd");
    spawnSync(["mkfifo", fifo]);
    mkdirSync(join(home, ".clauntty"), { recursive: true });
    await Bun.write(join(home, ".clauntty/active"), `${fifo}\n`);
    const listen = () => spawn(["cat", fifo], { stdout: "pipe" });

    const { workspace, pane: a } = wsJson(["new", "proj", "--cwd", project, "--quiet"]);
    let app = listen();
    const { pane: b } = wsJson(["split", a]);
    expect((await new Response(app.stdout).text()).trim()).toBe(`workspace;${workspace}/${b}`);

    app = listen();
    wsJson(["close", b]);
    expect((await new Response(app.stdout).text()).trim()).toBe("workspace;");

    app = listen();
    wsJson(["split", a, "--quiet"]);
    await Bun.sleep(200);
    expect(app.exitCode).toBeNull();
    app.kill();
  });

  test("outside rtach, PANE defaults to the pane the app shows", async () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    // What a master writes while its Clauntty client is the active one
    await Bun.write(join(home, ".clauntty/active"), `${socket(a)}.cmd\n`);
    const { pane: b } = wsJson(["split", "-v"]);
    expect(list()[0].tabs[0].layout).toEqual({ split: "v", ratio: 0.5, a, b });
  });

  test("add makes a running session a one-pane workspace", async () => {
    const id = "ADD0BEEF-0000-4000-8000-000000000001";
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
    spawnSync([RTACH_BIN, "-n", socket(id), "/bin/sh"], { cwd: home, env: env() });

    const [added] = wsJson(["add", id]);
    expect(added.pane).toBe(id);
    const [w] = list();
    expect(w.id).toBe(added.workspace);
    expect(w.tabs[0].layout).toBe(id);

    const again = spawnSync([RTACH_BIN, "ws", "add", id], { cwd: home, env: env() });
    expect(again.exitCode).toBe(1);
    expect(again.stderr.toString()).toContain("already in a workspace");
  });

  test("end stops every pane and removes the workspace", async () => {
    const { workspace, pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const { pane: b } = wsJson(["split", a]);
    wsJson(["end", workspace]);
    expect(list()).toEqual([]);
    expect(await waitFor(() => !existsSync(socket(a)) && !existsSync(socket(b)))).toBe(true);
  });

  test("clauntty ws is rtach ws", () => {
    const bin = join(home, "bin");
    mkdirSync(bin);
    symlinkSync(RTACH_BIN, join(bin, "clauntty"));
    const result = spawnSync([join(bin, "clauntty"), "ws", "new", "proj", "--cwd", project], { cwd: home, env: env() });
    expect(result.exitCode).toBe(0);
    const { workspace } = JSON.parse(result.stdout.toString());
    expect(list().map((w) => w.id)).toEqual([workspace]);
  });

  // The command is typed at the new pane's first prompt; the shell stays after it
  for (const shell of ["/bin/zsh", "/bin/bash"]) {
    test(`-- CMD runs in the new pane's ${shell}`, async () => {
      const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
      // From inside another pane, whose shell already has the integration
      const { pane: b } = wsJson(["split", a, "--", "echo", "ran-$((6*7))"], {
        env: { SHELL: shell, CLAUNTTY_SHELL_INTEGRATION: "1" },
      });
      const client = attach(b);
      // Not the command line: that still says $((6*7))
      await waitForOutput(client, "ran-42", 3000);
      client.stdin.write("echo alive-$((1+1)) run=${CLAUNTTY_RUN:-unset}\n");
      expect(await waitForOutput(client, "alive-2", 3000)).toContain("alive-2 run=unset");
    });
  }

  test("-- CMD needs a shell with the integration", () => {
    const { pane: a } = wsJson(["new", "proj", "--cwd", project]);
    const result = spawnSync([RTACH_BIN, "ws", "split", a, "--", "true"], { cwd: home, env: env() });
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("needs bash, zsh or fish");
  });

  test("errors say what's wrong", () => {
    const result = spawnSync([RTACH_BIN, "ws", "split"], { cwd: home, env: env() });
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("not inside an rtach session, and Clauntty shows none");
  });
});
