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
- `src/shell_integration.zig` - Shell integration scripts
- `src/ws.zig` - `rtach ws`: workspaces, tabs and split layouts over sessions
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

The master keeps each client's last `winch` size. The PTY takes the size of the client in use: the latest claim or input, else the latest attach, among clients that are attached and not paused. A `pause` also gives up the size until the client claims or types again, so a background pre-fetch (resume, then pause) doesn't take it back. When the client in use pauses, detaches or disconnects, the next one's size applies right away. With no such client, the size stays. Tests: `tests/size-handoff.test.ts`.

### Session start

`-A` takes an exclusive `flock` on `<socket>.lock`, then connects to the socket. If a master answers, it attaches. Otherwise (no socket, or a stale one) it forks a master and holds the lock until the master signals, over a pipe, that it listens. The lock file is never removed (that would let two processes hold different "locks"). A master removes its socket and `.cmd` FIFO on exit only if the path still has the inode it created. Tests: `tests/session-lock.test.ts`.

### Workspaces (`rtach ws`)

A pane is an ordinary session. `~/.clauntty/workspaces/<id>.json` groups panes: `{id, name, cwd, tabs: [{id, name, layout}]}`, where `layout` is a pane id or `{"split":"h|v","ratio","a","b"}` and a tab's panes are its leaves in order. Changes go through `rtach ws new|tab|split|close|move|rename|list [--json]`, under one flock on `workspaces/.lock`, with temp file plus rename. PANE arguments default to `$RTACH_SESSION_ID` (set in every session, with `RTACH_SOCKET`). New panes start in the workspace's `cwd` (the git root for `ws new`) by running this binary's `-n`, so they go through spawnd. Don't start them with `std.process.run`: its children get the Io's environment, which is empty. A master that exits takes its pane out (`ws.paneEnded`); `list` drops panes whose master doesn't answer. A tab's last pane takes the tab, a workspace's last tab the workspace. Changes send `workspace;<ws>/<pane>` (or `workspace;`) through `cli.notify` to the session the app shows on this machine (active pointer), else this session's pipe; the app refreshes and shows the new pane. The app's own `ws` commands pass `--quiet`. Tests: `tests/workspaces.test.ts`, each with its own HOME under /tmp (socket paths max 104 bytes on macOS).

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
