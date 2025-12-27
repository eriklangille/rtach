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
| Protocol | Raw | Framed with handshake |
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

# Show help
rtach --help

# Show version
rtach --version
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
6. Protocol handshake and upgrade

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

rtach 2.0 uses a framed protocol with handshake for reliable communication.

### Protocol Upgrade Flow

```
Client connects
       │
       ▼
┌──────────────┐
│  RAW MODE    │  Both directions: unframed data
│              │  (client sends raw, server sends raw)
└──────┬───────┘
       │
       │  Server sends handshake frame
       ▼
┌──────────────┐
│   UPGRADE    │  Client receives handshake, sends upgrade packet
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ FRAMED MODE  │  Both directions: framed packets
│              │  (all data wrapped in [type][len][payload])
└──────────────┘
```

### Client → Server Packets

```
┌──────┬──────┬──────────────────────────┐
│ type │ len  │ payload (up to 255 bytes)│
│ 1B   │ 1B   │ variable                 │
└──────┴──────┴──────────────────────────┘
```

| Type | Name | Payload |
|------|------|---------|
| 0 | `push` | Terminal input data |
| 1 | `attach` | Client ID (16 bytes, optional) |
| 2 | `detach` | None |
| 3 | `winch` | rows (2B) + cols (2B) |
| 4 | `redraw` | None |
| 5 | `request_scrollback` | None (legacy) |
| 6 | `request_scrollback_page` | offset (4B) + limit (4B) |
| 7 | `upgrade` | None (switches to framed mode) |

### Server → Client Frames

```
┌──────┬──────────┬──────────────────────┐
│ type │   len    │ payload              │
│ 1B   │ 4B (LE)  │ variable             │
└──────┴──────────┴──────────────────────┘
```

| Type | Name | Payload |
|------|------|---------|
| 0 | `terminal_data` | PTY output |
| 1 | `scrollback` | Legacy scrollback data |
| 2 | `command` | Command from scripts |
| 3 | `scrollback_page` | meta (8B) + data |
| 255 | `handshake` | magic (4B) + version (2B) + flags (2B) |

### Handshake Format

```
┌────────────┬─────────────┬─────────────┬─────────┐
│   magic    │ ver_major   │ ver_minor   │  flags  │
│ "RTCH" 4B  │     1B      │     1B      │   2B    │
└────────────┴─────────────┴─────────────┴─────────┘
```

- Magic: `0x48435452` ("RTCH" little-endian)
- Version: Current protocol version (e.g., 2.0)
- Flags: Reserved for future use

### Why Protocol Upgrade?

The upgrade protocol solves a key problem: **the client may not know if rtach is running**.

- If rtach is running: handshake is sent, client upgrades to framed mode
- If rtach is NOT running (e.g., `--help`, error, or direct shell): raw output is passed through to terminal
- Client scans incoming data for handshake pattern, forwarding non-handshake data as terminal output
- This allows raw output (help text, errors) to be displayed before the session starts

## Version History

| Version | Changes |
|---------|---------|
| 2.0.1 | Protocol upgrade flow, framed terminal data |
| 2.0.0 | Framed protocol with handshake |
| 1.9.0 | Command pipe ($RTACH_CMD_FD) |
| 1.8.x | Cursor visibility, SIGWINCH fixes |
| 1.7.0 | Client ID for deduplication |
| 1.6.x | Paginated scrollback |
| 1.5.0 | Initial scrollback limit (16KB) |

## References

- dtach source: https://github.com/crigler/dtach
- libxev: https://github.com/mitchellh/libxev
- Clauntty: https://github.com/eriklangille/clauntty
