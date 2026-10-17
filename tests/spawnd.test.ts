import { describe, test, expect, beforeEach, afterEach } from "bun:test";
import { spawn, type Subprocess } from "bun";
import { chmodSync, existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  RTACH_BIN,
  uniqueSocketPath,
  cleanupAll,
  trackProcess,
  waitForOutput,
  waitForSocket,
} from "./helpers";

/**
 * spawnd (macOS)
 *
 * When spawnd answers, a client that has to create a master asks spawnd to run
 * `rtach --no-spawnd -n ...` with the client's environment and working directory,
 * then attaches as usual. Without spawnd the client starts the master itself.
 * Here spawnd runs by hand on its own socket; under launchd it's the same code.
 */

describe.skipIf(process.platform !== "darwin")("spawnd", () => {
  let dir: string;
  let spawndSocket: string;
  let spawnd: Subprocess<"ignore", "pipe", "pipe">;
  let spawndLog = "";
  let socketPath: string;
  let script: string;
  let startsFile: string;

  beforeEach(async () => {
    dir = realpathSync(mkdtempSync(join(tmpdir(), "rtach-test-spawnd-")));
    spawndSocket = join(dir, "spawnd.sock");
    socketPath = uniqueSocketPath();
    startsFile = join(dir, "starts");
    script = join(dir, "prog.sh");
    // Prints where it runs and what it was given, and records each start
    writeFileSync(
      script,
      `#!/bin/sh\necho "$$" >> ${startsFile}\necho "cwd=$(pwd) var=$SPAWND_TEST_VAR"\nexec cat\n`
    );
    chmodSync(script, 0o755);

    spawndLog = "";
    spawnd = spawn([RTACH_BIN, "spawnd", "run"], {
      env: { ...process.env, RTACH_SPAWND_SOCKET: spawndSocket },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    (async () => {
      for await (const chunk of spawnd.stderr) spawndLog += new TextDecoder().decode(chunk);
    })();
    expect(await waitForSocket(spawndSocket)).toBe(true);
  });

  afterEach(async () => {
    spawnd.kill(9);
    await spawnd.exited;
    await cleanupAll();
  });

  function attach(spawndPath: string): Subprocess {
    const workdir = join(dir, "work");
    Bun.spawnSync(["mkdir", "-p", workdir]);
    return trackProcess(
      spawn([RTACH_BIN, "-A", socketPath, "-E", script], {
        cwd: workdir,
        env: { ...process.env, RTACH_SPAWND_SOCKET: spawndPath, SPAWND_TEST_VAR: "from-client" },
        stdin: "pipe",
        stdout: "pipe",
        stderr: "pipe",
      })
    );
  }

  function starts(): number {
    return existsSync(startsFile) ? readFileSync(startsFile, "utf8").trim().split("\n").length : 0;
  }

  test("-A starts the master through spawnd, with the client's env and cwd", async () => {
    const client = attach(spawndSocket);
    const output = await waitForOutput(client, "var=", 3000);
    expect(output).toContain(`cwd=${join(dir, "work")} var=from-client`);
    expect(spawndLog).toContain(": exit 0");

    // The session works as usual
    client.stdin.write("ping-through-spawnd\n");
    expect(await waitForOutput(client, "ping-through-spawnd", 2000)).toContain("ping-through-spawnd");
    expect(starts()).toBe(1);
  });

  test("without spawnd, -A starts the master itself", async () => {
    const client = attach(join(dir, "nobody-here.sock"));
    const output = await waitForOutput(client, "var=", 3000);
    expect(output).toContain("var=from-client");
    expect(spawndLog).not.toContain(": exit");
  });

  test("concurrent -A through spawnd start one master", async () => {
    const clients = Array.from({ length: 10 }, () => attach(spawndSocket));
    await Promise.all(clients.map((c) => waitForOutput(c, "var=", 5000)));
    await Bun.sleep(300);
    expect(starts()).toBe(1);
    for (const c of clients) expect(c.exitCode).toBeNull();
  });
});
