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
- `src/ringbuffer.zig` - Scrollback buffer
- `src/shell_integration.zig` - Shell integration scripts

## Version Bumping

When releasing a new rtach version, update **both** files:

1. `src/main.zig` - Update `pub const version = "X.Y.Z"`
2. `../clauntty/Clauntty/Core/SSH/RtachDeployer.swift` - Update `static let expectedVersion = "X.Y.Z"`

The iOS app uses the version to determine when to redeploy the binary to remote servers.

## Protocol (v2.5)

- Magic: `RTCH` (0x48435452)
- Client→Server: `[type:1B][len:1B][payload]` (max 255B)
- Server→Client: `[type:1B][len:4B][payload]`
