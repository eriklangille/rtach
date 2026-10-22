import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { closeSync, constants, existsSync, openSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess, waitForOutput } from "./helpers";

/**
 * `clauntty show` (src/cli.zig), and `tab`, `forward` and `open`, which go the same way
 *
 * Each image gets an inbox entry (~/.clauntty/inbox/<id>: its path, then the pane that
 * sent it) and an `image;<id>;<pane>;<path>` command. The command goes to the session
 * the app shows (the active pointer), so the app hears about it even when the sending
 * pane is off screen, else to this session's pipe. A stand-in app pipe records it.
 */

describe("clauntty show", () => {
  let home: string;
  let id: string;
  let sock: string;
  let image: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/sessions"), { recursive: true });
    mkdirSync(join(home, ".clauntty/bin"));
    symlinkSync(RTACH_BIN, join(home, ".clauntty/bin/clauntty"));
    id = "5E55A000-0000-4000-8000-" + Math.random().toString(16).slice(2, 14).padEnd(12, "0");
    sock = join(home, ".clauntty/sessions", id);
    image = join(home, "shot.png");
    writeFileSync(image, "not really a png");
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => ({ ...process.env, HOME: home, SHELL: "/bin/sh" });
  const clauntty = () => join(home, ".clauntty/bin/clauntty");

  /** Stand in for the app: the active pointer names a pipe whose lines go to a file */
  async function app(): Promise<string> {
    const fifo = join(home, "app.cmd");
    spawnSync(["mkfifo", fifo]);
    writeFileSync(join(home, ".clauntty/active"), `${fifo}\n`);
    const log = join(home, "app.log");
    // Held open to read and write, as a master holds its pipe: a writer closing it is
    // never the end, which would stop `cat` between `show`'s check and its write
    trackProcess(spawn(["sh", "-c", `exec 3<> ${fifo}; exec cat <&3 >> ${log}`]));
    // Until it's open: opening the pipe to write fails while nobody reads
    for (let i = 0; i < 100; i++) {
      try {
        closeSync(openSync(fifo, constants.O_WRONLY | constants.O_NONBLOCK));
        break;
      } catch {
        await Bun.sleep(20);
      }
    }
    return log;
  }

  async function lines(log: string, count: number, timeoutMs = 3000): Promise<string[]> {
    const start = Date.now();
    let got: string[] = [];
    while (Date.now() - start < timeoutMs) {
      got = existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : [];
      if (got.length >= count) break;
      await Bun.sleep(50);
    }
    return got;
  }

  function inbox(): string[] {
    const dir = join(home, ".clauntty/inbox");
    return readdirSync(dir).filter((f) => !f.startsWith(".")).map((f) => readFileSync(join(dir, f), "utf8"));
  }

  async function session() {
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { cwd: home, env: env() });
    const client = trackProcess(spawn([RTACH_BIN, "-a", sock, "-E"], { env: env(), stdin: "pipe", stdout: "pipe", stderr: "pipe" }));
    await waitForOutput(client, "$ ", 3000);
    return client;
  }

  test("from a pane: the session the app shows gets it, with the pane", async () => {
    const log = await app();
    const client = await session();
    client.stdin.write(`${clauntty()} show ${image}\n`);
    await waitForOutput(client, "Sent 1 image to Clauntty", 3000);

    const [line] = await lines(log, 1);
    expect(line).toMatch(new RegExp(`^image;\\d+-\\d+-0;${id};${image}$`));
    expect(inbox()).toEqual([`${image}\n${id}`]);
  });

  test("outside rtach: no pane", async () => {
    const log = await app();
    const r = spawnSync([clauntty(), "show", image], { env: env() });
    expect(r.stdout.toString()).toContain("Sent 1 image to Clauntty");

    const [line] = await lines(log, 1);
    expect(line).toMatch(new RegExp(`^image;\\d+-\\d+-0;;${image}$`));
    expect(inbox()).toEqual([image]);
  });

  test("the app's session gone: this session's pipe takes it", async () => {
    // A pointer to a pipe nobody reads, as when the app's session ended
    const stale = join(home, "gone.cmd");
    spawnSync(["mkfifo", stale]);
    writeFileSync(join(home, ".clauntty/active"), `${stale}\n`);
    const client = await session();
    client.stdin.write(`${clauntty()} show ${image}\n`);
    await waitForOutput(client, "Sent 1 image to Clauntty", 3000);
    expect(inbox()).toEqual([`${image}\n${id}`]);
  });

  test("tab, forward and open go to the session the app shows too; tab says which pane", async () => {
    const log = await app();
    const client = await session();
    client.stdin.write(`${clauntty()} tab 8000 && ${clauntty()} forward :8001 && ${clauntty()} open http://localhost:8002/x\n`);
    await waitForOutput(client, "Port 8001 forwarded", 3000);

    expect(await lines(log, 3)).toEqual([`open;8000;${id}`, "forward;8001", "browser;http://localhost:8002/x"]);
  });

  test("tab outside rtach: no pane", async () => {
    const log = await app();
    const r = spawnSync([clauntty(), "tab", "8000"], { env: env() });
    expect(r.stdout.toString()).toContain("Opened port 8000");
    expect(await lines(log, 1)).toEqual(["open;8000;"]);
  });

  test("videos too, but not ones Apple's players can't play", async () => {
    const log = await app();
    const video = join(home, "demo.mov");
    writeFileSync(video, "not really a video");
    const r = spawnSync([clauntty(), "show", video], { env: env() });
    expect(r.exitCode).toBe(0);
    const [line] = await lines(log, 1);
    expect(line).toMatch(new RegExp(`^image;\\d+-\\d+-0;;${video}$`));

    const webm = join(home, "clip.webm");
    writeFileSync(webm, "");
    const refused = spawnSync([clauntty(), "show", webm], { env: env() });
    expect(refused.exitCode).not.toBe(0);
    expect(refused.stderr.toString()).toContain("not an image");
  });

  test("nowhere to send it: queued in the inbox", () => {
    const r = spawnSync([clauntty(), "show", image], { env: env() });
    expect(r.stdout.toString()).toContain("Queued 1 image");
    expect(inbox()).toEqual([image]);
  });
});
