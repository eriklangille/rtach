# Mosh vs rtach: Architecture Comparison & Improvement Roadmap

Analysis of mosh's architecture and what rtach can learn from it to improve performance, stability, and reliability.

**Date**: January 2026

## Executive Summary

Mosh and rtach solve similar problems (persistent remote terminal sessions) but with fundamentally different approaches:

- **Mosh**: UDP-based with custom reliability, full terminal state sync, client-side prediction
- **rtach**: TCP-based (via SSH), raw PTY streaming, scrollback buffering

Both have strengths. This document identifies improvements rtach can adopt from mosh while preserving rtach's unique advantages.

---

## Architecture Comparison

### Transport Layer

| Aspect | Mosh | rtach |
|--------|------|-------|
| Protocol | UDP with custom reliability | TCP via SSH tunnel |
| Authentication | SSH bootstrap → AES-128 session key | SSH throughout |
| Encryption | OCB mode (authenticated) | SSH channel encryption |
| MTU | 1280 bytes (conservative for mobile) | TCP handles fragmentation |
| Reconnection | Seamless IP roaming | New SSH connection required |

**Mosh's approach**: Uses SSH only for initial auth, then switches to UDP. This allows:
- No head-of-line blocking (lost packets don't stall stream)
- Seamless IP address changes (WiFi→cellular)
- Custom retransmission timing optimized for terminals

**rtach's approach**: Relies entirely on SSH/TCP. This provides:
- Simpler implementation (no custom reliability layer)
- Works through firewalls that block UDP
- Proven security model

### State Model

| Aspect | Mosh | rtach |
|--------|------|-------|
| Server state | Full terminal framebuffer | Raw PTY output buffer |
| Sync method | Diff-based (old state → new state) | Stream-based (append only) |
| Compression | zlib on diffs | None |
| Scrollback | None (client-side only) | Server-side ring buffer |

**Mosh's approach**: Server maintains complete terminal state (VT100 emulator + framebuffer). Sends diffs:
```
Old: [A][B][C]
New: [A][X][C]
Diff: "cell 1: B→X"
```

**rtach's approach**: Server buffers raw PTY output. Client maintains terminal state via GhosttyKit.

### Client-Side Prediction

| Aspect | Mosh | rtach |
|--------|------|-------|
| Local echo | Full prediction engine | None |
| Visual feedback | Underlined predictions | N/A |
| Confidence | Adaptive (RTT-based) | N/A |
| Parser | Full terminal emulator clone | N/A |

Mosh's prediction engine is its killer feature for perceived latency.

---

## Mosh Deep Dive

### Packet Structure

```
[16-bit timestamp][sequence + direction bit][encrypted payload]
```

- Timestamps in both directions enable RTT calculation
- Direction bit (bit 63) distinguishes client→server from server→client
- Sequence numbers for ordering and deduplication

### RTT Calculation (Karn's Algorithm)

```cpp
SRTT = 0.875 * SRTT + 0.125 * sample
RTTVAR = 0.75 * RTTVAR + 0.25 * |SRTT - sample|
RTO = SRTT + 4 * RTTVAR  // bounded [50ms, 1000ms]
```

Used for:
- Send interval: `ceil(SRTT / 2)` bounded [20ms, 250ms]
- Prediction display thresholds
- Retransmission timing

### Prediction Engine

Three display modes:
- **Always**: Show predictions immediately
- **Never**: Wait for server confirmation
- **Adaptive**: Show based on RTT thresholds

Thresholds:
| Threshold | Value | Action |
|-----------|-------|--------|
| SRTT_TRIGGER | 30ms | Start showing predictions |
| FLAG_TRIGGER | 80ms | Underline predictions |
| GLITCH_TRIGGER | 250ms | Assume network glitch |
| GLITCH_FLAG | 5000ms | Strong underline |

Confidence states:
```
Pending → Correct → Expired
              ↓
         Incorrect
```

### Echo Acknowledgment

```
Client: keystroke with frame_number=100
Server: processes, sends echo_ack=100
Client: removes underline from prediction
```

Allows client to know which input was confirmed.

### Roaming / IP Changes

**Client-side port hopping**:
```cpp
if (now - last_port_choice > 10s && now - last_success > 10s) {
    hop_port();  // Create new socket
}
```

**Server-side roaming**:
- Detects client IP change from packet source
- Updates remote address automatically
- "Server attached to client at X:Y" notification

### Frame Rate Adaptation

```cpp
send_interval = ceil(SRTT / 2);  // [20ms, 250ms]
collect_window = 8ms;  // Batch input before sending
```

Prevents overwhelming slow connections.

---

## rtach Deep Dive

### Protocol (v2.5.x)

Two-phase: Raw mode → Framed mode (after upgrade handshake)

**Client→Server** (max 255 bytes):
```
[type: 1B][len: 1B][payload]
```

| Type | Name | Purpose |
|------|------|---------|
| 0 | push | Terminal input |
| 1 | attach | Connect with client ID |
| 2 | detach | Graceful disconnect |
| 3 | winch | Window resize |
| 4 | redraw | Request screen replay |
| 5 | request_scrollback | Legacy: all scrollback |
| 6 | request_scrollback_page | Paginated scrollback |
| 7 | upgrade | Switch to framed mode |
| 8 | pause | Stop output streaming |
| 9 | resume | Resume + flush buffer |

**Server→Client** (max 4GB):
```
[type: 1B][len: 4B LE][payload]
```

| Type | Name | Purpose |
|------|------|---------|
| 0 | terminal_data | PTY output |
| 1 | scrollback | Legacy scrollback |
| 2 | command | Script commands via FIFO |
| 3 | scrollback_page | Paginated response |
| 4 | idle | Shell idle notification |
| 255 | handshake | Protocol negotiation |

### Scrollback Ring Buffer

```zig
RingBuffer(T, capacity) {
    buffer: [capacity]T,
    head: usize,  // Write position
    len: usize,   // Current size
}
```

- O(1) writes with circular wrap
- Two-slice API for wrap-around reads
- Range queries for paginated access

### Pause/Resume (Battery Optimization)

```
pause → stop sending terminal_data
         (scrollback continues buffering)
resume → flush buffered data since pause
         resume normal streaming
```

Critical for iOS battery life.

### Shell Integration

- Title parsing (OSC 0/1/2)
- Idle detection (2s threshold)
- Command FIFO (`RTACH_CMD_PIPE`)
- Integration scripts for bash/zsh/fish

---

## Improvement Roadmap

### Priority 1: Compression (Low Effort, High Impact)

**What**: Add zlib compression to terminal_data frames.

**Why**: Terminal output is highly compressible (repeated spaces, ANSI escapes). Reduces latency on slow connections.

**Implementation**:
```zig
// Protocol change
const FrameFlags = packed struct {
    compressed: bool,
    reserved: u7,
};

// In master.zig
const compressed = std.compress.zlib.compress(data);
if (compressed.len < data.len) {
    writeFramedCompressed(client, compressed);
} else {
    writeFramed(client, data);
}
```

**Considerations**:
- Mosh uses 4MB ring buffer for compression dictionary state
- Could use per-frame compression (simpler) or stateful (better ratio)
- Add compression level config (1-9)

---

### Priority 2: RTT Measurement (Medium Effort, High Impact)

**What**: Add timestamps to protocol for RTT calculation.

**Why**: Foundation for adaptive behavior, connection quality indicators, prediction.

**Implementation**:
```zig
// Add to handshake or as new message type
const Ping = struct {
    client_time: u16,  // Milliseconds mod 65536
};

const Pong = struct {
    client_time: u16,  // Echo back
    server_time: u16,  // Server's timestamp
};
```

**Use cases**:
- Show connection quality in iOS UI
- Adapt batching window based on RTT
- Inform future prediction confidence

---

### Priority 3: Frame Batching (Low Effort, Medium Impact)

**What**: Coalesce PTY output over short window before sending.

**Why**: Reduces syscalls, improves efficiency on slow links.

**Implementation**:
```zig
// In master.zig event loop
const BATCH_WINDOW_MS = 8;
var batch_buffer: std.ArrayList(u8);
var batch_timer: ?i64 = null;

fn onPtyRead(data: []const u8) void {
    batch_buffer.appendSlice(data);
    if (batch_timer == null) {
        batch_timer = now() + BATCH_WINDOW_MS;
        scheduleFlush(BATCH_WINDOW_MS);
    }
}

fn flushBatch() void {
    broadcastToClients(batch_buffer.items);
    batch_buffer.clearRetainingCapacity();
    batch_timer = null;
}
```

**Considerations**:
- Control-C should bypass batching (immediate send)
- Disable batching when measured RTT < 10ms

---

### Priority 4: Echo Acknowledgment (Medium Effort, Medium Impact)

**What**: Track input sequence numbers, confirm receipt to client.

**Why**: Enables prediction confidence, detection of dropped input.

**Implementation**:
```zig
// Client sends
const Push = struct {
    seq: u32,  // Incrementing sequence number
    data: []const u8,
};

// Server includes in response
const TerminalData = struct {
    echo_ack: u32,  // Last processed input seq
    data: []const u8,
};
```

**iOS client changes**:
- Track pending input sequences
- Show indicator for unacknowledged input
- Remove indicator when echo_ack >= seq

---

### Priority 5: Client-Side Prediction (High Effort, High Impact)

**What**: Predict keystroke effects locally, show immediately.

**Why**: Makes typing feel instant on high-latency connections.

**Architecture**:
```
┌─────────────────────────────────────────┐
│ GhosttyKit Terminal                     │
│  ┌─────────────┐  ┌─────────────────┐   │
│  │ Real State  │  │ Predicted State │   │
│  │ (confirmed) │  │ (speculative)   │   │
│  └─────────────┘  └─────────────────┘   │
│         ↑                  ↑            │
│    server data      local keystrokes    │
└─────────────────────────────────────────┘
```

**Implementation approach**:
1. Maintain shadow terminal state for predictions
2. Apply keystrokes to shadow immediately
3. Display shadow state with prediction styling
4. Reconcile when server response arrives
5. Use RTT to decide when to show predictions

**Considerations**:
- GhosttyKit already has full terminal emulator
- Need to handle prediction failures gracefully
- Complex for cursor movement, special keys
- Start with simple character echo, expand later

---

### Priority 6: Connection Quality Indicator (Low Effort, Medium Impact)

**What**: Expose connection metrics to iOS UI.

**Why**: Users understand "slow connection" better than mysterious lag.

**Implementation**:
```swift
// In RtachClient
struct ConnectionQuality {
    let rtt: TimeInterval
    let level: Level

    enum Level {
        case excellent  // < 50ms
        case good       // < 150ms
        case fair       // < 300ms
        case poor       // >= 300ms
    }
}

// UI shows colored indicator
```

---

### Priority 7: Adaptive Idle Detection (Low Effort, Low Impact)

**What**: Adjust idle threshold based on RTT.

**Current**: Fixed 2s threshold.

**Improved**:
```zig
const idle_threshold = @max(2000, measured_rtt * 10);
```

---

### Priority 8: Diff-Based Sync (High Effort, Medium Impact)

**What**: Send terminal state diffs instead of raw output.

**Why**: More efficient on slow connections, enables smarter reconnection.

**Considerations**:
- Requires terminal emulator on server (could embed Ghostty's Zig terminal)
- Significant architectural change
- May not be worth complexity given rtach's scrollback advantage

**Recommendation**: Defer unless compression + prediction prove insufficient.

---

## What rtach Does Better

| Feature | rtach | mosh |
|---------|-------|------|
| Scrollback | Server-side ring buffer | None (client only) |
| Session persistence | Survives server reboot | Dies with server |
| Shell integration | Title, idle, command FIFO | None |
| Battery optimization | Pause/resume | Always streaming |
| Protocol simplicity | Framed over TCP | Custom UDP reliability |
| I/O model | Modern (io_uring/kqueue) | select() |
| Firewall compatibility | Works everywhere SSH works | UDP may be blocked |

---

## Implementation Phases

### Phase 1: Quick Wins (1-2 weeks)
- [ ] Add compression flag to protocol
- [ ] Implement zlib compression for terminal_data
- [ ] Add frame batching (8ms window)
- [ ] Add ping/pong messages for RTT

### Phase 2: Foundation (2-4 weeks)
- [ ] RTT calculation (SRTT/RTTVAR)
- [ ] Echo acknowledgment protocol
- [ ] Connection quality metrics to iOS
- [ ] Adaptive batching based on RTT

### Phase 3: Prediction (4-8 weeks)
- [ ] Shadow terminal state in GhosttyKit
- [ ] Simple character prediction
- [ ] Prediction styling (underline)
- [ ] Reconciliation on server response
- [ ] Adaptive prediction thresholds

### Phase 4: Polish (ongoing)
- [ ] Adaptive idle detection
- [ ] Prediction for cursor movement
- [ ] Compression dictionary persistence
- [ ] Performance benchmarking

---

## References

- [Mosh: An Interactive Remote Shell for Mobile Users](https://mosh.org/mosh-paper.pdf) - Original paper
- [Mosh source code](https://github.com/mobile-shell/mosh)
- rtach protocol: `rtach/src/protocol.zig`
- GhosttyKit terminal: `ghostty/src/terminal/`
