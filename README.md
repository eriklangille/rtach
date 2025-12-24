# rtach - Modern Terminal Session Manager

A modern replacement for dtach, built with Zig and libxev for high-performance terminal session persistence with scrollback replay.

## Motivation

**Problem**: When using SSH terminals (like Clauntty), network disconnects kill your session. dtach solves session persistence but has limitations:

1. **No scrollback buffer** - On reattach, screen is blank until new output
2. **Uses `select()`** - O(n) performance, outdated API
3. **No cross-platform async I/O** - No kqueue/epoll/io_uring support

**Solution**: rtach adds scrollback replay while using modern async I/O via libxev.

## Goals

1. **Drop-in dtach compatibility** - Same CLI flags, same behavior
2. **Scrollback replay** - Buffer terminal output, replay on reattach
3. **Modern I/O** - kqueue (macOS), epoll (Linux), io_uring (Linux 5.1+)
4. **Easy cross-compilation** - Zig compiles to any target trivially
5. **Full testability** - Integration tests validate dtach parity

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    rtach master                         │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────┐    ┌─────────────┐    ┌────────────┐  │
│  │  Unix Socket│◄──►│  Ring Buffer│◄───│    PTY     │  │
│  │  (clients)  │    │ (scrollback)│    │  (shell)   │  │
│  └─────────────┘    └─────────────┘    └────────────┘  │
│         │                                    │         │
│         └──────── libxev event loop ─────────┘         │
│                   (kqueue/epoll/io_uring)              │
└─────────────────────────────────────────────────────────┘
```

## Key Differences from dtach

| Feature | dtach | rtach |
|---------|-------|-------|
| Event loop | `select()` | libxev (kqueue/epoll/io_uring) |
| Scrollback | None | Configurable ring buffer |
| On reattach | Blank screen | Replay buffered output |
| Language | C | Zig |
| Build | autoconf | `zig build` |
| Cross-compile | Manual | `zig build -Dtarget=...` |

## Usage

```bash
# Create session or attach if exists (most common)
rtach -A /tmp/session $SHELL

# Attach to existing session
rtach -a /tmp/session

# Create new session
rtach -c /tmp/session bash

# Create detached (no attach)
rtach -n /tmp/session bash

# Custom scrollback size (4MB)
rtach -A /tmp/session -s 4194304 claude
```

## Building

```bash
# Native build
zig build

# Run
zig build run -- -A /tmp/test bash

# Cross-compile for deployment
zig build cross

# Run tests
zig build test
```

## Deployment Strategy

rtach is designed to be auto-deployed by Clauntty to remote servers:

1. Clauntty bundles rtach binaries for x86_64 and aarch64 Linux
2. On SSH connect, check if `~/.clauntty/bin/rtach` exists
3. If not, SFTP upload the correct binary for server architecture
4. Run: `~/.clauntty/bin/rtach -A ~/.clauntty/sessions/{id} $SHELL`

## Testing

Integration tests use Bun to validate:
1. Session creation and persistence
2. Detach/reattach cycle
3. Scrollback buffer replay
4. Window resize handling
5. Multi-client attach
6. Exact dtach CLI compatibility

```bash
# Run integration tests
cd tests && bun test
```

## Files

| File | Purpose |
|------|---------|
| `src/main.zig` | CLI entry point, argument parsing |
| `src/master.zig` | Master process: PTY, socket, event loop |
| `src/client.zig` | Client attach logic, terminal raw mode |
| `src/ringbuffer.zig` | Scrollback storage |
| `src/protocol.zig` | Packet format for client-master communication |

## Protocol

Same packet format as dtach for compatibility:

```
┌──────┬──────┬──────────────────────────┐
│ type │ len  │ payload (up to 255 bytes)│
│ 1B   │ 1B   │ variable                 │
└──────┴──────┴──────────────────────────┘
```

Message types:
- `MSG_PUSH` (0) - Data from client to master
- `MSG_ATTACH` (1) - Client attach request
- `MSG_DETACH` (2) - Client detach
- `MSG_WINCH` (3) - Window size change
- `MSG_REDRAW` (4) - Request redraw

## References

- dtach source: https://github.com/crigler/dtach
- libxev: https://github.com/mitchellh/libxev
- Clauntty: https://github.com/eriklangille/clauntty
