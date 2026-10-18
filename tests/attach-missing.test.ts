import { describe, test, expect, afterEach } from "bun:test";
import { spawnSync } from "bun";
import { mkdtempSync, realpathSync, rmSync } from "fs";
import { join } from "path";
import { RTACH_BIN, cleanupAll } from "./helpers";

/**
 * `-a` (attach only) on a session that doesn't exist exits 3, so the app can tell a
 * closed session from a dropped connection, and doesn't re-create it with `-A`.
 */

describe("attach to a missing session", () => {
  let dir: string;

  afterEach(async () => {
    await cleanupAll();
    if (dir) rmSync(dir, { recursive: true, force: true });
  });

  test("no socket: exit 3", () => {
    dir = realpathSync(mkdtempSync("/tmp/rtach-test-"));
    const r = spawnSync([RTACH_BIN, "--proxy", "-a", join(dir, "gone"), "-E"], { stdin: "ignore" });
    expect(r.exitCode).toBe(3);
  });

  test("a socket no master answers: exit 3", () => {
    dir = realpathSync(mkdtempSync("/tmp/rtach-test-"));
    const sock = join(dir, "stale");
    // A master that exits leaves no socket, but one killed outright can
    spawnSync([RTACH_BIN, "-n", sock, "/bin/sh"], { env: { ...process.env, SHELL: "/bin/sh" } });
    spawnSync(["pkill", "-9", "-f", `rtach.*${sock}`]);
    spawnSync(["sleep", "0.3"]);
    const r = spawnSync([RTACH_BIN, "--proxy", "-a", sock, "-E"], { stdin: "ignore" });
    expect(r.exitCode).toBe(3);
  });
});
