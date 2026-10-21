# rtach

Terminal session persistence for Clauntty.

## Build

```bash
zig build                   # Build
zig build test              # Unit tests
zig build integration-test  # Functional tests (bun)
zig build cross             # Cross-compile all targets
```

## Files

- `src/main.zig` - CLI entry
- `src/master.zig` - Server: PTY, socket, event loop
- `src/client.zig` - Client: attach, raw terminal
- `src/protocol.zig` - Wire protocol
- `src/compression.zig` - zlib wrapper for terminal data compression
- `src/ringbuffer.zig` - Scrollback buffer
- `src/shell_integration.zig` - Shell integration scripts, and the startup-file wrappers in `~/.clauntty/shell-integration` (zsh: ZDOTDIR points there, so every zsh startup file needs a wrapper or the user's is skipped)
- `src/ws.zig` - `rtach ws`: workspaces, tabs and split layouts over sessions
- `src/picker.zig` - `rtach` with no arguments (or `clauntty` in a terminal): the workspaces and panes the app shows, for a laptop terminal. Enter attaches; the client returning (Ctrl+\ or the pane ending) comes back to the list after resetting the modes the program left on. `n`, `N` and `x` run `ws.call`, which tells the app to refresh but not to switch (each device keeps its own place). Tests: `tests/picker.test.ts`, in a Bun PTY.
- `src/spawnd.zig` - macOS LaunchAgent that starts masters in the desktop session
- `src/sys.zig` - Thin wrappers for fd, socket and process calls (Zig 0.16 removed most `std.posix` ones; files go through `std.Io`)

## Version Bumping

When releasing a new rtach version, update **both** files:

1. `src/main.zig` - Update `pub const version = "X.Y.Z"`
2. `../clauntty/Clauntty/Core/SSH/RtachDeployer.swift` - Update `static let expectedVersion = "X.Y.Z"`

The iOS app uses the version to determine when to redeploy the binary to remote servers.

## Protocol (v2.6)

- Magic: `RTCH` (0x48435452)
- Client→Server: `[type:1B][len:1B][payload]` (max 255B)
- Server→Client: `[type:1B][len:4B][payload]`
- Active claim: `[type=10][len=0]` (foreground client for commands)

### Terminal size

The master keeps each client's last `winch` size. The PTY takes the size of the client in use: the latest claim or input, else the latest attach, among clients that are attached and not paused. A `pause` also gives up the size until the client claims or types again (`yielded`), so a background pre-fetch (resume, then pause) doesn't take it back. So does an attach with ATTACH_FLAG_BACKGROUND (`rtach --proxy --background`, what the app runs since 2.32.0): loading a pane isn't using it, so the phone opening no longer resizes the panes a laptop is using. Yielded clients only get the size when they are the only client attached: a device that is attached but not using the pane (paused, or only viewing it) leaves the size where it is, so a laptop switching away from a pane, or fetching it in the background, never moves it. A `claim_active` with payload byte CLAIM_FLAG_COMMANDS_ONLY routes commands and workspace news to the client without taking the size or counting as use (the phone at launch, in the foreground, switching windows); a plain claim (Tap to use here, the Mac app in front) takes it. The proxy forwards claims as they are. Input that's only the client's terminal answering the program (`query_filter.onlyReplies`: cursor position, device attributes, mode, color and window reports, focus in/out) is passed on but doesn't count as use: with two devices showing Claude Code, which asks after each redraw, each answer took the size and the pane flipped between them many times a second. When the client in use pauses, detaches or disconnects, the next one's size applies right away. With no such client, the size stays. A client that sends `want_size` (type 12; the handshake has flag `1 << 1` when the master answers it) gets `pty_size` (response 7: rows u16, cols u16, flags u8 with bit 0 "yours") right away and whenever the PTY's size, or whether it's that client's, changes. The app then draws a pane a laptop is using at the laptop's size, scaled to fit, and says it's in use on another device; older clients never ask, because they don't skip unknown response types. The proxy forwards `want_size`. Tests: `tests/size-handoff.test.ts`.

### Session start

`-A` takes an exclusive `flock` on `<socket>.lock`, then connects to the socket. If a master answers, it attaches. Otherwise (no socket, or a stale one) it forks a master and holds the lock until the master signals, over a pipe, that it listens. The lock file is never removed (that would let two processes hold different "locks"). A master removes its socket and `.cmd` FIFO on exit only if the path still has the inode it created, and before the socket its `.state`, `.title` and `.log`. A master that crashes or is killed can't: `rtach sweep [--json]` (run by the app after `rtach upgrade`, once per host per launch) deletes what sessions with no master left, except their `.log`, which it keeps 7 days as the only record of why the session died. It skips sessions whose `-A` lock is held or whose files changed in the last minute (a master that's starting can look dead), and deletes a lock only while holding it. Tests: `tests/sweep.test.ts`. Tests: `tests/session-lock.test.ts`. `-a` (attach only) exits 3 when there's no session (no socket, or no master on it), so the app can tell a session that ended from a dropped connection. The app's workspace tabs attach with `-a`: with `-A`, a tab reconnecting just after its pane was closed (or its shell exited) re-created the session. Tests: `tests/attach-missing.test.ts`. When a session ends (its shell exits, or the master is stopped), the master sends `ended` (a command frame) to every framed client before closing them, so the app ends the window at once instead of reconnecting to find no session. A live upgrade doesn't send it. Tests: `tests/ended.test.ts`.

### Workspaces (`rtach ws`)

A pane is an ordinary session. `~/.clauntty/workspaces/<id>.json` groups panes: `{id, name, cwd, tabs: [{id, name, layout}]}`, where `layout` is a pane id or `{"split":"h|v","ratio","a","b"}` and a tab's panes are its leaves in order. `workspaces/order` is a JSON array of ids: `list` and the picker follow it, then any it doesn't have, oldest first; every save rewrites it. `ws new` goes after `--after WS`, else the current pane's workspace, else last; `ws reorder WS [--before OTHER]` moves one. `ws resize PANE OTHER RATIO` sets the split between two panes (the smallest holding both), PANE's side getting RATIO (kept 0.1–0.9); the Mac app's divider sends it. Changes go through `rtach ws new|tab|split|close|end|add|move|rename|reorder|resize|list [--json]`, under one flock on `workspaces/.lock`, with temp file plus rename. PANE arguments default to `$RTACH_SESSION_ID` (set in every session, with `RTACH_SOCKET`), else the pane the app shows (`~/.clauntty/active`), so an agent outside rtach can act on what the user is looking at. New panes start in the workspace's `cwd` (the git root for `ws new`) by running this binary's `-n`, so they go through spawnd. A new pane doesn't get its caller's environment, only what a session the app opens over SSH would have: `pane_env` in `ws.zig` (HOME, USER, SHELL, TERM, the locale, …), the system's default PATH, then the shell's startup files. With the caller's whole environment, a pane an agent opened (`clauntty ws new -- claude`) belonged to that agent: a Claude there inherited `CLAUDECODE` and `CLAUDE_CODE_SESSION_ID` and took itself for the agent's child (no transcript, the parent's messaging socket). Don't start them with `std.process.run`: its children get the Io's environment, which is empty. `new|tab|split ... -- CMD` puts CMD in the pane's `CLAUNTTY_RUN`; the shell integration (bash, zsh, fish; others are refused) runs it at the first prompt (zsh: typed and accepted in ZLE) and unsets it, so the shell stays when it ends. A master clears `CLAUNTTY_SHELL_INTEGRATION` for its shell, which a pane started from another pane inherits. `clauntty ws` is `rtach ws` (`ws.run`). A master that exits takes its pane out (`ws.paneEnded`); `list` drops panes whose master doesn't answer. A tab's last pane takes the tab, a workspace's last tab the workspace. Changes send `workspace;<ws>/<pane>` (or `workspace;`) through `cli.notify` to the session the app shows on this machine (active pointer), else this session's pipe; the app refreshes and shows the new pane. The app's own `ws` commands pass `--quiet`, except `reorder` and `resize`, so another device showing the host refreshes. The app makes every tab a workspace: a new tab is `ws new`, Close is `ws end`, and sessions in no workspace are adopted with `ws add`. Tests: `tests/workspaces.test.ts`, each with its own HOME under /tmp (socket paths max 104 bytes on macOS).

### Every device hears changes (`active.devicePath`)

Besides the single active pointer (the device in use), each device has one: when a client with a client id claims active, its master writes `~/.clauntty/devices/<id in hex>` with its command FIFO, and clears it when that client leaves (unless another of its clients is still attached there). `cli.notify` (workspace changes from `ws`, agents' state from masters) writes `@<id>;<kind>;<value>` to each device's FIFO, and that master gives it to that device's client only (`sendCommandToDevice`); a FIFO nobody reads drops its pointer. A `workspace;<ws>/<pane>` (show the new pane) also goes the old way, to the device in use only; the others get `workspace;` (refresh). Without device pointers, the old way alone. Tests: `tests/devices.test.ts`.

### Modes restored on attach (`src/term_modes.zig`)

The replay is the last 16KB (none on the alternate screen), so state a program set at startup is
before the cut. `TermModes` follows the raw PTY output and the master sends a new client
`restoreSequence` after the replay: DEC flags (DECCKM, ?1004, ?2004, ?2031), mouse event and
format, autowrap, cursor visibility, the keypad mode (`ESC =`), xterm's key modifier options
(`ESC [ > 4 ; 2 m`, modifyOtherKeys), the cursor style (DECSCUSR) and the kitty keyboard flags.
Claude Code pushes kitty flags (`ESC [ > 5 u`) and sets modifyOtherKeys at startup, on the normal
screen; without them back, the terminal sent the older key encodings after a reattach. Kitty flags
are a stack per screen, as in Ghostty: on the alternate screen the main screen's go out before the
`?1049h`. RIS (`ESC c`) resets everything. They carry through a live upgrade (`upgrade.State`). Not
tracked: the scroll region and origin mode (size-dependent), colors, charsets. Tests: unit tests in
`term_modes.zig`, `tests/functional.test.ts` ("restores terminal modes"), `tests/upgrade.test.ts`.

### Ready after an attach

A client that attaches with ATTACH_FLAG_READY (the app's proxy, `rtach --proxy --ready`; the handshake has HANDSHAKE_FLAG_READY) gets `ready` (response 8, empty) when the screen is ready to show. A shell's comes right after the replay. A program on the alternate screen gets no replay and only redraws on a real size change (Node ignores a SIGWINCH at the same size), so unless the attach changed the size, the master nudges (`startNudge`): the PTY one row short of `winsize` until the program's next output (outside a synchronized frame, `TermModes.sync_frame`), or NUDGE_TIMEOUT_NS on the idle tick, then back, then `ready`. That client doesn't get the program's output meanwhile (the short redraw); after `ready` comes the redraw at the real size. A real size change meanwhile ends the nudge. A program busy writing anyway (a spinner) can write before it reads the change, which ends the nudge early. Tests: `tests/ready.test.ts`.

### Pane state (`src/pane_state.zig`)

The master probes the terminal's foreground process every second (`tcgetpgrp`, then libproc on macOS or `/proc` on Linux) for its name and directory. Agent state comes from hooks: `clauntty agent-state working|blocked|done|idle|end` (Claude Code's hooks, deployed by the app) writes `state;<status>;<note>` to `$RTACH_CMD_PIPE`, which the master handles instead of forwarding; outside an rtach session the command does nothing. Without hooks, Claude Code's title counts (spinner: working, ✳: idle). The UserPromptSubmit hook's prompt becomes the pane's `task` (a `task;` line before the state line): its first line, without `[Image #n]`/`[Pasted text …]` placeholders, cut to 120 bytes; slash commands don't count, and SessionStart (`idle`) or `end` clears it. The app titles an agent pane with it when Claude's own title is just "Claude Code". On a change the master writes `<socket>.state` (one JSON line) and, for sessions in `~/.clauntty/sessions`, sends `pane;<id>;<json>` to the app through `cli.notify`. `ws list --json` includes each pane's state, and `ws split` starts in the split pane's directory. Tests: `tests/pane-state.test.ts` (own HOME, a stand-in app pipe).

### Push notifications (`src/push.zig`)

A phone that's away (suspended, so not attached) hears about an agent through APNs. The app writes one line per phone to `~/.clauntty/push`: `<worker url> <device key> <phone id>`. When a pane's status changes to `done` or `blocked`, its master builds a notice (`push.line`: `<pane>;<kind>;<title>;<body>`, the title being the workspace and the agent's name) and sends `push;<notice>` to the session the app shows (`cli.notifyActive`), or handles it itself when there's none. The master handling it (`Master.handlePush`) does nothing if an app client there is attached and not paused; otherwise it runs `curl` for each line, posting JSON on stdin to `<url>/notify` (BusyBox `wget` where there is no curl, as on Alpine). A grandchild runs it so the master never waits. The same status again within 10s doesn't push again (an agent going blocked, working, blocked). The Worker is `clauntty/push/` in the app repo. Tests: `tests/push.test.ts` (a stand-in curl on PATH).

### Commands for the app (`src/cli.zig`)

`clauntty show`, `tab`, `forward` and `open` go to the session the app shows on this machine (the active pointer, if its master answers), else to this session's pipe (`appTarget`). The app lets idle panes' channels go, so a pane's own pipe may have no app client, and its master drops commands it can't pass on. `tab` sends `open;<port>;<pane>` so the app files the page under that pane's workspace (`<pane>` empty outside rtach; older rtach sent `open;<port>`). Tests: `tests/show.test.ts`.

### Images (`clauntty show`, `src/inbox.zig`)

`clauntty show IMG...` writes an inbox entry per image (`~/.clauntty/inbox/<id>`: the path, then on a second line the pane that sent it) and sends `image;<id>;<pane>;<path>` (the pane is `$RTACH_SESSION_ID`, empty outside rtach) to the session the app shows, else to this session's pipe. Going through the shown session means an image from a pane that's off screen still arrives right away. In agent mode the app puts it in the corner of that pane's window. The app deletes an entry once it has shown it, and shows entries left behind when it connects. Tests: `tests/show.test.ts`.

### Live upgrade (`src/upgrade.zig`)

A running session moves to a newer rtach without ending. `upgrade;<rtach>` on its command pipe makes the master (after the rest of that read) write `<socket>.resume` and `execve` the new binary as `rtach --resume <socket> <pty fd> <socket fd> <pipe fd> <shell pid>`. Same process, so the shell stays its child; the PTY, listening socket and pipe stay open (close-on-exec is cleared on those three and set on every other fd, so the event loop's fds don't survive to steal PTY reads). Clients are shut down and reattach: the app reconnects, and a terminal client (`client.zig`, e.g. a laptop in the picker) reconnects to the same socket by itself when the connection closed without `ended`, attaching with `ATTACH_FLAG_RESUME` (an attach payload byte after the optional client id). The new master then sends it only what it wrote since it took over (`resumed_at`), no replay and no modes, so nothing shows twice. A master that's gone refuses the connection and the client exits. The running client is the binary the terminal started, so the upgrade that ships a client change still drops it once. The state file is the first line JSON (`upgrade.State`: scrollback size and position, modes, title, pane state, a partial pipe line), then the scrollback's bytes. What keeps the session is on the command line, so a state file the new version can't read (`format` mismatch, bad JSON) only costs the scrollback. Fields can be added without bumping `format`: readers ignore unknown ones and default missing ones. An upgrade that can't happen (not executable, the binary it already runs, exec fails) leaves the master running as it was. `rtach upgrade [--json] [SESSION...]` sends `upgrade;<this binary>` to every master whose `.state` reports an older `"rtach"` version (2.19.0+ write it; older masters are "too old" and need a restart) and waits up to 5s for them to report the new one. The app runs it from `RtachDeployer.ensureDeployed`, once per host per launch. Tests: `tests/upgrade.test.ts`.

### spawnd (macOS)

A master started over SSH is in macOS's Background session, where the login keychain isn't available, so code signing fails inside the session. `rtach spawnd install` copies rtach to `~/.clauntty/bin/rtach-spawnd` (the app's cleanup deletes only `rtach-<version>` binaries) and loads a LaunchAgent (`com.clauntty.rtach-spawnd`, Aqua only). launchd listens on `~/.clauntty/spawnd.sock` and starts spawnd on the first connection; spawnd exits after a minute idle. When a client has to create a master and spawnd answers, spawnd runs `<the client's rtach> --no-spawnd -n ...` with the client's environment and cwd, and the client attaches as usual. If spawnd doesn't reply within 3s (launchd accepts the connection even when it can't start spawnd), the client starts the master itself unless one now answers. Without spawnd the client starts the master itself (Linux, or spawnd not installed). Without spawnd, a client on macOS that isn't in the desktop session (`launchctl managername` isn't `Aqua`) has the master write a one-line notice to the terminal before the shell starts. The app offers to install spawnd on Mac hosts (once per run) and reruns `install` when spawnd's copy differs from the deployed rtach. `rtach spawnd status|uninstall`; log in `~/.clauntty/spawnd.log`. `RTACH_SPAWND_SOCKET` overrides the socket (empty: don't use spawnd; `tests/.env.test` sets that). Tests: `tests/spawnd.test.ts`.

### Compression

Terminal data can be compressed to reduce bandwidth (30-60% savings on typical output).

**Upgrade packet** (client→server):
- No compression: `[type=7][len=0]`
- With compression: `[type=7][len=1][compression_type]`
  - `compression_type=0x00`: none
  - `compression_type=0x01`: deflate

**Response compression** (server→client):
- High bit (0x80) of type byte indicates compression
- `type=0x00`: uncompressed terminal_data
- `type=0x80`: deflate-compressed terminal_data
- Only data ≥64 bytes is compressed (overhead not worth it for small packets)

**Format**: Uses **raw deflate (RFC 1951)** without zlib header/trailer. This is compatible with Apple's `COMPRESSION_ZLIB` which expects raw deflate despite the name. Do NOT use zlib format (RFC 1950) with header/checksum.

**Compatibility**: Clients sending `[7,0]` (CLI/raw terminals) get uncompressed responses. iOS Swift client sends `[7,1,0x01]` to request compression.

## Dependencies

- **libxev**: Event loop, upstream mitchellh/libxev pinned to the same commit as ghostty
- **zlib**: Compression (compiled from source via [allyourcodebase/zlib](https://github.com/allyourcodebase/zlib) for cross-compilation support)
