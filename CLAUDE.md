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

## Version Bumping

When releasing a new rtach version, update **both** files:

1. `src/main.zig` - Update `pub const version = "X.Y.Z"`
2. `../clauntty/Clauntty/Core/SSH/RtachDeployer.swift` - Update `static let expectedVersion = "X.Y.Z"`

The iOS app uses the version to determine when to redeploy the binary to remote servers.

## Protocol (v2.6)

- Magic: `RTCH` (0x48435452)
- Client→Server: `[type:1B][len:1B][payload]` (max 255B)
- Server→Client: `[type:1B][len:4B][payload]`
- Active claim: `[type=10][len=0]` (foreground client for size/commands)

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

- **libxev**: Event loop (local fork at `../libxev`)
- **zlib**: Compression (compiled from source via [allyourcodebase/zlib](https://github.com/allyourcodebase/zlib) for cross-compilation support)
