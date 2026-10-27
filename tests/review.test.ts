import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, spawnSync } from "bun";
import { closeSync, constants, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll, trackProcess } from "./helpers";

/**
 * `clauntty review` (src/review.zig)
 *
 * Bundles a change in ~/.clauntty/reviews/<id>.json (the diff, each file's old and new
 * contents, the notes), sends `review;<id>;<pane>` the way `show` sends images, then
 * waits: the app writes the user's comments to <id>.reply, which the command takes by
 * renaming it, prints, and exits. A stand-in app pipe records the command.
 */

describe("clauntty review", () => {
  let home: string;
  let repo: string;
  let notes: string;

  beforeEach(() => {
    home = realpathSync(mkdtempSync("/tmp/rtach-test-home-"));
    mkdirSync(join(home, ".clauntty/bin"), { recursive: true });
    symlinkSync(RTACH_BIN, join(home, ".clauntty/bin/clauntty"));
    repo = join(home, "repo");
    mkdirSync(repo);
    const git = (...args: string[]) =>
      spawnSync(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", ...args], { cwd: repo });
    git("init", "-q");
    writeFileSync(join(repo, "a.txt"), "one\ntwo\nthree\n");
    writeFileSync(join(repo, "package-lock.json"), "{}\n");
    git("add", ".");
    git("commit", "-qm", "base");
    writeFileSync(join(repo, "a.txt"), "one\nTWO\nthree\nfour\n");
    writeFileSync(join(repo, "package-lock.json"), '{"a":1}\n');
    writeFileSync(join(repo, "new.txt"), "fresh\n");
    notes = join(home, "notes.json");
    writeFileSync(notes, JSON.stringify({ title: "t", files: [{ path: "a.txt", priority: "critical" }] }));
  });

  afterEach(async () => {
    await cleanupAll();
    rmSync(home, { recursive: true, force: true });
  });

  const env = () => {
    const e: Record<string, string | undefined> = { ...process.env, HOME: home, RTACH_SESSION_ID: "pane-1" };
    delete e.RTACH_CMD_PIPE;
    return e;
  };
  const reviews = () => join(home, ".clauntty/reviews");

  /** Stand in for the app: the active pointer names a pipe whose lines go to a file */
  async function app(): Promise<string> {
    const fifo = join(home, "app.cmd");
    spawnSync(["mkfifo", fifo]);
    writeFileSync(join(home, ".clauntty/active"), `${fifo}\n`);
    const log = join(home, "app.log");
    trackProcess(spawn(["sh", "-c", `exec 3<> ${fifo}; exec cat <&3 >> ${log}`]));
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

  async function bundleId(): Promise<string> {
    for (let i = 0; i < 200; i++) {
      const json = existsSync(reviews()) ? readdirSync(reviews()).find((f) => f.endsWith(".json")) : undefined;
      if (json) return json.slice(0, -5);
      await Bun.sleep(20);
    }
    throw new Error("no bundle");
  }

  test("bundles the change, tells the app, prints the reply", async () => {
    const log = await app();
    const proc = trackProcess(spawn([join(home, ".clauntty/bin/clauntty"), "review", notes, "--repo", repo], { env: env(), stdout: "pipe" }));
    const id = await bundleId();

    const bundle = JSON.parse(readFileSync(join(reviews(), `${id}.json`), "utf8"));
    expect(bundle.pane).toBe("pane-1");
    expect(bundle.working_tree).toBe(true);
    expect(bundle.notes.title).toBe("t");
    const byPath = Object.fromEntries(bundle.files.map((f: any) => [f.path, f]));
    expect(byPath["a.txt"]).toMatchObject({ status: "modified", old: "one\ntwo\nthree\n", new: "one\nTWO\nthree\nfour\n", added: 2, removed: 1 });
    // Collapsed: no contents, no diff, but counted
    expect(byPath["package-lock.json"]).toMatchObject({ skipped: "lockfile", added: 1, removed: 1 });
    expect(byPath["package-lock.json"].new).toBeUndefined();
    expect(byPath["new.txt"]).toMatchObject({ status: "untracked", new: "fresh\n", added: 1 });
    expect(bundle.diff).toContain("+TWO");
    expect(bundle.diff).toContain("+fresh");
    expect(bundle.diff).not.toContain("package-lock.json");

    await Bun.sleep(100);
    expect(readFileSync(log, "utf8")).toBe(`review;${id};pane-1\n`);

    // The app's reply, written as it does: a temp file renamed into place
    writeFileSync(join(reviews(), `${id}.reply.tmp`), 'Review of "t": looks good');
    renameSync(join(reviews(), `${id}.reply.tmp`), join(reviews(), `${id}.reply`));
    expect(await proc.exited).toBe(0);
    const out = await new Response(proc.stdout).text();
    expect(out).toContain("waiting for comments");
    expect(out).toContain('Review of "t": looks good\n');
    // Taken and cleaned up
    expect(readdirSync(reviews())).toEqual([]);
  });

  test("exits when the review is closed without comments", async () => {
    const proc = trackProcess(spawn([join(home, ".clauntty/bin/clauntty"), "review", notes, "--repo", repo], { env: env(), stdout: "pipe" }));
    const id = await bundleId();
    rmSync(join(reviews(), `${id}.json`));
    expect(await proc.exited).toBe(0);
    const out = await new Response(proc.stdout).text();
    expect(out).toContain("queued");
    expect(out).toContain("closed without comments");
  });

  test("compares two commits with a..b", async () => {
    spawnSync(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qam", "second"], { cwd: repo });
    writeFileSync(notes, JSON.stringify({ base: "HEAD~1..HEAD" }));
    trackProcess(spawn([join(home, ".clauntty/bin/clauntty"), "review", notes, "--repo", repo], { env: env(), stdout: "pipe" }));
    const id = await bundleId();
    const bundle = JSON.parse(readFileSync(join(reviews(), `${id}.json`), "utf8"));
    expect(bundle.working_tree).toBe(false);
    expect(bundle.range).toMatch(/^HEAD~1 \([0-9a-f]+\) → HEAD \([0-9a-f]+\)$/);
    // Untracked files aren't part of a commit range
    expect(bundle.files.map((f: any) => f.path).sort()).toEqual(["a.txt", "package-lock.json"]);
    rmSync(join(reviews(), `${id}.json`));
  });

  test("fails outside a repository or with an unknown ref", () => {
    const outside = spawnSync([join(home, ".clauntty/bin/clauntty"), "review", notes, "--repo", home], { env: env() });
    expect(outside.exitCode).toBe(1);
    expect(outside.stderr.toString()).toContain("not in a git repository");
    const unknown = spawnSync([join(home, ".clauntty/bin/clauntty"), "review", notes, "--repo", repo, "--base", "nope"], { env: env() });
    expect(unknown.exitCode).toBe(1);
    expect(unknown.stderr.toString()).toContain("unknown ref: nope");
  });
});
