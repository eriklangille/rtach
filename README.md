# rtach - Modern Terminal Session Manager

A modern replacement for dtach, built with Zig and libxev for high-performance terminal session persistence with scrollback replay.

## Why rtach?

dtach provides session persistence but lacks scrollback replay and uses outdated `select()`. rtach adds scrollback buffer replay and modern async I/O (kqueue/epoll/io_uring) via libxev.

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

```bash
zig build test              # Unit tests
zig build integration-test  # Functional tests (requires bun)
zig build test-all          # Both
```

## Files

| File | Purpose |
|------|---------|
| `src/main.zig` | CLI entry point, argument parsing |
| `src/master.zig` | Master process: PTY, socket, event loop |
| `src/client.zig` | Client attach logic, terminal raw mode |
| `src/protocol.zig` | Packet format for client-master communication |
| `src/ringbuffer.zig` | Scrollback storage |
| `src/shell_integration.zig` | Shell integration for bash/zsh/fish |

## Protocol

rtach uses a framed protocol (v2.x) with handshake for reliable communication.

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
| 3 | `winch` | rows (2B) + cols (2B) + xpixel (2B) + ypixel (2B) |
| 4 | `redraw` | None |
| 5 | `request_scrollback` | None (legacy) |
| 6 | `request_scrollback_page` | offset (4B) + limit (4B) |
| 7 | `upgrade` | None (switches to framed mode) |
| 8 | `pause` | None (pause terminal output streaming) |
| 9 | `resume` | None (resume terminal output streaming) |
| 10 | `claim_active` | None (mark client as active) |

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
| 4 | `idle` | None (shell idle, sent after 2s of no PTY output) |
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

Upgrade allows raw output (help text, errors) to pass through before rtach starts, while enabling framed mode once handshake is received.

## Version History

| Version | Changes |
|---------|---------|
| 2.7.2 | Active client claims for size + command routing |
| 2.5.x | FIFO command channel (RTACH_CMD_PIPE), multiline paste fix |
| 2.4.0 | Shell integration (bash/zsh/fish title updates) |
| 2.3.0 | OSC title parsing (.title file for session picker) |
| 2.1.0 | Pause/resume/idle for battery optimization |
| 2.0.x | Framed protocol with handshake |
| 1.9.0 | Command pipe |
| 1.8.x | Cursor visibility, SIGWINCH fixes |
| 1.7.0 | Client ID for deduplication |
| 1.6.x | Paginated scrollback |

## References

- dtach source: https://github.com/crigler/dtach
- libxev: https://github.com/mitchellh/libxev
- Clauntty: https://github.com/eriklangille/clauntty
