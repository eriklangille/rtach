import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * Push notifications (src/push.zig)
 *
 * When an agent finishes or is blocked, the pane's master sends a `push;` notice to the
 * session the app shows (the active pointer); without one it handles it itself. The
 * master handling it runs curl for each phone in ~/.clauntty/push, unless the app is
 * attached there in the foreground. A stand-in curl on PATH records what it gets.
 */

describe("push", () => {
  let home: string;
  let id: string;
  let sock: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
    mkdirSync(join(home, ".clauntty/bin"));
    symlinkSync(RTACH_BIN, join(home, ".clauntty/bin/clauntty"));
    mkdirSync(join(home, "bin"));
    writeFileSync(
      join(home, "bin/curl"),
      `#!/bin/sh\necho "$@" > "$HOME/curl.$$.args"\n/bin/cat > "$HOME/curl.$$.json"\n`,
    );
    chmodSync(join(home, "bin/curl"), 0o755);
    writeFileSync(
      join(home, ".clauntty/push"),
      "https://push.example/ key-one phone-1\nhttps://push.example key-two phone-2\n",
    );
    id = "5E55A000-0000-4000-8000-" + Math.random().toString(16).slice(2, 14).padEnd(12, "0");
    sock = join(home, ".clauntty/sessions", id);
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh", PATH: `${join(home, "bin")}:${process.env.PATH}` });

  async function start() {
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: home, env: env() });
    const client = trackProcess(spawn([RTACH_BIN, "-a", sock, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await waitForOutput(client, "$ ", 3000);
    return client;
  }

  /** What curl was sent: [args, body] per call */
  async function pushes(count: number, timeoutMs = 4000): Promise<{ args: string; body: any }[]> {
    const start = Date.now();
    let calls: { args: string; body: any }[] = [];
    while (Date.now() - start < timeoutMs) {
      const files = readdirSync(home).filter((f) => f.startsWith("curl.") && f.endsWith(".json"));
      calls = files.flatMap((f) => {
        const text = readFileSync(join(home, f), "utf8");
        if (!text.endsWith("}")) return [];
        return [{ args: readFileSync(join(home, f.replace(".json", ".args")), "utf8").trim(), body: JSON.parse(text) }];
      });
      if (calls.length >= count) break;
      await Bun.sleep(100);
    }
    return calls;
  }

  test("an agent finishing with no app around pushes to every phone", async () => {
    const client = await start();
    writeFileSync(join(home, "prompt.json"), JSON.stringify({ prompt: "fix the keyboard flicker" }));
    client.stdin.write("~/.clauntty/bin/clauntty agent-state working < ~/prompt.json\n");
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");

    const calls = await pushes(2);
    expect(calls.length).toBe(2);
    expect(calls.every((c) => c.args.endsWith("https://push.example/notify"))).toBe(true);
    expect(calls.map((c) => c.body.key).sort()).toEqual(["key-one", "key-two"]);
    expect(calls[0].body).toMatchObject({ pane: id, kind: "done", title: "fix the keyboard flicker", body: "Finished" });
  });

  test("blocked pushes the hook's note, once while it flaps", async () => {
    writeFileSync(join(home, ".clauntty/push"), "https://push.example key-one phone-1\n");
    const client = await start();
    const hook = (state: string) =>
      client.stdin.write(`echo '{"message":"Claude needs your permission to use Bash"}' | ~/.clauntty/bin/clauntty agent-state ${state}\n`);
    hook("blocked");
    expect((await pushes(1)).length).toBe(1);
    hook("working");
    hook("blocked");
    await Bun.sleep(1000);

    const calls = await pushes(2, 300);
    expect(calls.length).toBe(1);
    expect(calls[0].body).toMatchObject({ kind: "blocked", body: "Claude needs your permission to use Bash" });
  });

  test("goes to the session the app shows, which decides", async () => {
    const appFifo = join(home, "app.cmd");
    spawnSync(["mkfifo", appFifo]);
    writeFileSync(join(home, ".clauntty/active"), `${appFifo}\n`);
    const appLog = join(home, "app.log");
    // Held open for reading and writing, as a master holds its pipe, so a writer never
    // finds it without a reader
    spawn(["sh", "-c", `exec 3<>${appFifo}; cat <&3 >> ${appLog}`]);

    const client = await start();
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");

    await Bun.sleep(1500);
    const lines = readFileSync(appLog, "utf8").split("\n").filter((l) => l.startsWith("push;"));
    expect(lines).toEqual([`push;${id};done;Claude;Finished`]);
    expect((await pushes(1, 300)).length).toBe(0);
  });

  test("without curl, BusyBox wget posts it", async () => {
    rmSync(join(home, "bin/curl"));
    writeFileSync(join(home, "bin/wget"), `#!/bin/sh\necho "$@" > "$HOME/curl.$$.args"\n/bin/cat > "$HOME/curl.$$.json"\n`);
    chmodSync(join(home, "bin/wget"), 0o755);
    // Only the stand-in: no real curl on PATH (the shell and hooks go by full path)
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: home, env: { ...env(), PATH: join(home, "bin") } });
    const client = trackProcess(spawn([RTACH_BIN, "-a", sock, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await waitForOutput(client, "$ ", 3000);
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");

    const calls = await pushes(2);
    expect(calls.length).toBe(2);
    expect(calls[0].args).toContain("--post-file /dev/stdin https://push.example/notify");
    expect(calls[0].body).toMatchObject({ pane: id, kind: "done" });
  });

  test("no push file, no curl", async () => {
    rmSync(join(home, ".clauntty/push"));
    const client = await start();
    client.stdin.write("~/.clauntty/bin/clauntty agent-state done < /dev/null\n");
    await Bun.sleep(1500);
    expect((await pushes(1, 300)).length).toBe(0);
  });
});
