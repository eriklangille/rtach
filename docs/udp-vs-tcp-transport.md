# UDP vs TCP for Interactive Terminals: Mosh's Transport Layer

Deep dive into mosh's custom UDP protocol and why it outperforms TCP/SSH for interactive terminal use.

**Date**: January 2026

---

## Why Not TCP?

TCP was designed for reliable bulk data transfer, not interactive applications. For terminals, this creates specific problems:

### 1. Head-of-Line Blocking

**Problem**: TCP guarantees in-order delivery. If packet 5 is lost, packets 6-10 are buffered until 5 arrives.

```
User types: h e l l o
Packets:    [1] [2] [3] [4] [5]
                     ↑ lost

TCP behavior:
  - Packets 4, 5 buffered waiting for 3
  - User sees nothing until retransmit completes
  - Entire stream stalls for one lost packet
```

**Impact**: On a 2% loss rate with 100ms RTT, expect 200ms+ stalls regularly.

**Mosh solution**: UDP + state-based sync. Lost packets don't block newer data—client displays latest received state.

### 2. Retransmission Ambiguity

**Problem**: TCP can't distinguish between:
- Packet lost (needs retransmit)
- ACK delayed (no action needed)
- Packet duplicated (ignore)

This forces conservative timeouts, often 1-3 seconds on first loss.

**Mosh solution**: Explicit timestamps in every packet enable precise RTT measurement:
```cpp
RTO = SRTT + 4 * RTTVAR  // bounded [50ms, 1000ms]
```

### 3. Congestion Control Mismatch

**Problem**: TCP's slow-start and congestion avoidance optimize for throughput, not latency:
- Takes time to ramp up on new connections
- Resets window on loss
- Exponential backoff can take seconds

**Mosh solution**: Frame rate tied to RTT, not congestion window:
```cpp
send_interval = ceil(SRTT / 2);  // bounded [20ms, 250ms]
```

No slow-start. Adapts per-packet, not per-connection.

### 4. Connection Binding

**Problem**: TCP connections are bound to `(src_ip, src_port, dst_ip, dst_port)`. Any change breaks the connection.

```
Phone on WiFi: 192.168.1.50 → SSH server
Phone switches to cellular: 10.0.0.1
Result: Connection dead, must re-authenticate
```

**Mosh solution**: UDP is connectionless. Server accepts packets from any IP with valid encryption:
```cpp
if (received_packet_from_different_IP) {
    remote_addr = new_addr;  // Just update, keep going
}
```

### 5. Buffering Prevents Speculation

**Problem**: SSH over TCP must wait for server response. Can't echo locally because:
- Stream is ordered—can't show data before it "arrives"
- Protocol doesn't support speculative rendering

**Mosh solution**: State-based sync allows client to predict and render immediately, then reconcile.

---

## Mosh Packet Format

### Network Layer

```
┌─────────────────────────────────────────────────────────────┐
│                    UDP Packet                                │
├─────────────────────────────────────────────────────────────┤
│  Nonce (8 bytes)                                            │
│  ├─ Bit 63: Direction (1=server→client, 0=client→server)   │
│  └─ Bits 0-62: Sequence number                              │
├─────────────────────────────────────────────────────────────┤
│  Encrypted Payload (AES-128 OCB)                            │
│  ├─ Timestamp (2 bytes, network order)                      │
│  ├─ Timestamp Reply (2 bytes, echo for RTT)                 │
│  └─ Fragment(s)                                             │
└─────────────────────────────────────────────────────────────┘
```

### Fragment Format

```
┌─────────────────────────────────────────────────────────────┐
│  Fragment Header (10 bytes)                                  │
│  ├─ Instruction ID (8 bytes): Unique per message            │
│  └─ Fragment Number (2 bytes)                                │
│      ├─ Bit 15: Final flag (1=last fragment)                │
│      └─ Bits 0-14: Fragment index (0, 1, 2, ...)            │
├─────────────────────────────────────────────────────────────┤
│  Payload: Compressed protobuf (variable)                    │
└─────────────────────────────────────────────────────────────┘
```

### Instruction (Protobuf)

```protobuf
message Instruction {
  optional uint32 protocol_version = 1;  // Currently 2
  optional uint64 old_num = 2;           // Base state for diff
  optional uint64 new_num = 3;           // New state number
  optional uint64 ack_num = 4;           // ACK of received state
  optional uint64 throwaway_num = 5;     // GC marker
  optional bytes diff = 6;               // Compressed state diff
  optional bytes chaff = 7;              // Random padding (privacy)
}
```

---

## Reliability Without TCP

### State-Based ACKs (Not Packet-Based)

Traditional reliability ACKs individual packets. Mosh ACKs **entire state revisions**:

```
Sender state list:
┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐
│ State 0 │ → │ State 1 │ → │ State 2 │ → │ State 3 │
│ (ACK'd) │   │         │   │(assumed)│   │ (sent)  │
└─────────┘   └─────────┘   └─────────┘   └─────────┘
                              ↑
                    assumed_receiver_state
```

- `old_num`: Reference state for computing diff
- `new_num`: This state's number
- `ack_num`: Last state receiver confirmed

### Retransmission Strategy

No explicit NACK. Instead:

```cpp
void update_assumed_receiver_state() {
    assumed_receiver_state = sent_states.begin();  // Start at ACK'd

    for (each sent_state after ACK'd) {
        if (now - timestamp < timeout + ACK_DELAY) {
            // Recently sent, assume receiver has it
            assumed_receiver_state = this_state;
        } else {
            break;  // Too old, assume lost
        }
    }
}
```

If ACK doesn't arrive within timeout, sender falls back to diffing from last ACK'd state. This means:
- **Redundant data**: Same info may be sent multiple times
- **No blocking**: Latest state always sent, old losses don't stall
- **Idempotent**: Receiving same state twice is harmless

### Out-of-Order Handling

Fragments reassembled by ID:

```cpp
FragmentAssembly {
    current_id: u64,
    fragments: vector<Fragment>,
    fragments_arrived: count,
    fragments_total: count (from final flag),
}

add_fragment(frag):
    if frag.id != current_id:
        clear and start new assembly
    if already have this fragment:
        verify identical (security)
    if frag.is_final:
        fragments_total = frag.num + 1
    return (fragments_arrived == fragments_total)
```

States inserted in sorted order:
```cpp
for (existing in received_states):
    if existing.num > new_state.num:
        insert new_state before existing
        break
```

---

## RTT Measurement

### Timestamp Exchange

Every packet carries:
- **Timestamp**: Sender's 16-bit millisecond clock
- **Timestamp Reply**: Echo of last received timestamp

```
Client                              Server
   │                                   │
   │──── ts=1000, ts_reply=- ─────────>│
   │                                   │
   │<──── ts=5000, ts_reply=1000 ──────│
   │                                   │
   │ RTT = now - 1000 (if now=1050,   │
   │        RTT = 50ms)                │
```

### SRTT Calculation (RFC 6298 variant)

```cpp
if (RTT_sample < 5000ms) {  // Ignore outliers (Ctrl-Z pauses)
    if (!RTT_hit) {
        // First sample
        SRTT = R;
        RTTVAR = R / 2;
        RTT_hit = true;
    } else {
        // Subsequent samples
        RTTVAR = 0.75 * RTTVAR + 0.25 * |SRTT - R|;
        SRTT = 0.875 * SRTT + 0.125 * R;
    }
}
```

### Retransmission Timeout

```cpp
RTO = SRTT + 4 * RTTVAR;

// Bounded
if (RTO < 50ms)   RTO = 50ms;    // MIN_RTO
if (RTO > 1000ms) RTO = 1000ms;  // MAX_RTO
```

Example: 100ms RTT, 20ms variance → RTO = 180ms

---

## Flow Control

### Frame Rate Adaptation

```cpp
unsigned int send_interval() const {
    int interval = ceil(SRTT / 2.0);

    // Bounds
    if (interval < 20)  interval = 20;   // Max 50 fps
    if (interval > 250) interval = 250;  // Min 4 fps

    return interval;
}
```

### Input Batching

```cpp
const int SEND_MINDELAY = 8;  // ms

// Collect input for SEND_MINDELAY before sending
next_send = max(mindelay_clock + SEND_MINDELAY,
                last_send + send_interval());
```

### Receiver Backpressure

```cpp
// Prevent memory exhaustion from malicious sender
if (received_states.size() > 1024) {
    if (now < quench_timer) {
        discard(new_state);
    } else {
        quench_timer = now + 15000;  // Reset 15s timer
    }
}
```

---

## Congestion Control

### ECN Support

Mosh detects ECN (Explicit Congestion Notification) from IP layer:

```cpp
bool congestion = (*ecn_octet & 0x03) == 0x03;

if (congestion) {
    // Penalize timestamp by 500ms
    saved_timestamp -= CONGESTION_TIMESTAMP_PENALTY;
}
```

Sender interprets inflated RTT as congestion signal → backs off naturally.

### MTU Handling

```cpp
// Conservative defaults for mobile
const int DEFAULT_IPV4_MTU = 1280;
const int DEFAULT_IPV6_MTU = 1280;

// On EMSGSIZE error, fall back
if (errno == EMSGSIZE) {
    MTU = 500;  // Very conservative
}
```

---

## Roaming

### Client-Side Port Hopping

```cpp
const int PORT_HOP_INTERVAL = 10000;  // 10 seconds

if ((now - last_port_choice > PORT_HOP_INTERVAL) &&
    (now - last_roundtrip_success > PORT_HOP_INTERVAL)) {
    hop_port();  // Create new socket with new local port
}
```

Maintains deque of active sockets, prunes after 60 seconds.

### Server-Side Roaming

```cpp
void received_packet(addr source) {
    if (source != remote_addr) {
        // Client moved (WiFi → cellular)
        remote_addr = source;
        log("Server attached to client at %s", source);
    }
}
```

Server detaches if no packet received for 40 seconds.

---

## Security

### Nonce/Sequence Enforcement

```cpp
if (packet.seq < expected_seq) {
    // Out-of-order: accept payload but don't update timing
    return packet.payload;
}

expected_seq = packet.seq + 1;
```

Prevents:
- Replay attacks (old packets rejected by sequence)
- Timing attacks (out-of-order packets don't affect RTT)
- Injection (authenticated encryption verifies sender)

### Direction Field

Bit 63 of nonce distinguishes direction:

```cpp
const uint64_t DIRECTION_MASK = 1ULL << 63;

direction = (nonce & DIRECTION_MASK) ? TO_CLIENT : TO_SERVER;

// Verify
assert(packet.direction == expected_direction);
```

Prevents server packets being replayed as client packets.

### Idempotency

```cpp
// Check if state already received
for (state in received_states) {
    if (inst.new_num == state.num) {
        return;  // Duplicate, ignore
    }
}

// Check if base state available
bool found = false;
for (state in received_states) {
    if (inst.old_num == state.num) {
        found = true;
        break;
    }
}

if (!found) {
    return;  // Can't apply diff, base was GC'd
}
```

---

## Comparison: Mosh UDP vs rtach over SSH

| Aspect | Mosh UDP | rtach/SSH (TCP) |
|--------|----------|-----------------|
| **Packet loss** | Non-blocking, show latest | Stream stalls until retransmit |
| **Retransmit timing** | 50-1000ms (measured) | 1-3s (conservative) |
| **IP roaming** | Seamless | Connection dies |
| **Congestion** | Frame rate adapts | cwnd-based, slow-start |
| **Buffering** | State-based, droppable | Stream-based, ordered |
| **Firewall** | UDP may be blocked | TCP/22 usually allowed |
| **Complexity** | Custom reliability layer | Relies on TCP |
| **Auth model** | SSH bootstrap → session key | SSH throughout |

---

## What This Means for rtach

### Can't Adopt (Architectural)

1. **UDP transport**: Would require reimplementing SSH auth, encryption, and reliability
2. **Seamless roaming**: TCP connections are fundamentally bound to IP:port tuples
3. **Non-blocking loss recovery**: TCP guarantees ordering

### Can Adopt (Within TCP)

1. **RTT measurement**: Add ping/pong messages within rtach protocol
2. **Frame batching**: Coalesce output over 8ms windows
3. **Adaptive timeouts**: Use measured RTT for idle detection, etc.
4. **Client-side prediction**: Independent of transport layer

### Potential Hybrid Approach

Could add optional UDP mode for LAN/trusted networks:

```
┌─────────────────────────────────────────────┐
│ iOS Client                                   │
│  ┌─────────────┐  ┌─────────────────────┐   │
│  │ SSH/TCP     │  │ UDP (optional)      │   │
│  │ (firewall-  │  │ (low-latency mode   │   │
│  │  friendly)  │  │  for trusted nets)  │   │
│  └─────────────┘  └─────────────────────┘   │
└─────────────────────────────────────────────┘
```

This would require:
- UDP listener on server (security implications)
- Session key exchange over SSH
- Fallback to TCP when UDP blocked

**Recommendation**: Focus on prediction and compression first. UDP transport is significant complexity for marginal gain when prediction provides similar perceived latency improvement.

---

## References

- [Mosh: An Interactive Remote Shell for Mobile Users](https://mosh.org/mosh-paper.pdf) - Original paper
- [RFC 6298](https://tools.ietf.org/html/rfc6298) - Computing TCP's Retransmission Timer
- Mosh source: `src/network/network.cc`, `src/network/transportfragment.cc`
