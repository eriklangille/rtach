# UDP Terminal Protocol: Security Design Considerations

Exploring what it would take to design a secure UDP-based terminal protocol from scratch.

**Date**: January 2026

---

## The Core Problem

TCP provides several security-relevant properties "for free":
- **Connection state**: Server knows who it's talking to
- **Source validation**: TCP handshake proves client controls the IP
- **Ordering**: Replay of old data is detected
- **Congestion fairness**: Can't easily flood the network

UDP provides none of these. A UDP terminal protocol must solve each explicitly.

---

## Threat Model

### Attackers

| Attacker | Capabilities | Goals |
|----------|--------------|-------|
| **Network observer** | See all packets | Read terminal session, steal credentials |
| **Active MITM** | Inject/modify packets | Inject commands, hijack session |
| **Off-path attacker** | Send packets, can't see traffic | DoS, blind injection, amplification |
| **Compromised client** | Full client access | Pivot to server, persist access |
| **Compromised server** | Full server access | Attack client, steal data |

### Assets to Protect

1. **Confidentiality**: Terminal I/O contains passwords, keys, sensitive data
2. **Integrity**: Injected commands could be catastrophic (`rm -rf /`)
3. **Availability**: Session should survive attacks
4. **Authentication**: Only authorized users can connect

---

## Security Challenges with UDP

### 1. Source IP Spoofing

**Problem**: UDP has no handshake. Anyone can send packets with forged source IP.

```
Attacker                    Server
   │                          │
   │── src=victim_ip ────────>│
   │                          │
   │     Server responds to   │
   │     victim, not attacker │
   │                          │
   ▼                          ▼
Victim receives unsolicited response (amplification attack)
```

**Why this matters for terminals**:
- Attacker could trigger server to send scrollback to victim (data leak)
- Amplification: 1 small request → large terminal dump
- Reflection: Use your server to attack third parties

**Mitigations**:
1. **Challenge-response**: Require client to prove it receives responses
2. **Cookie exchange**: Like DTLS, send stateless cookie first
3. **SSH bootstrap**: Establish session over TCP first (mosh approach)
4. **Rate limiting**: Limit responses to unverified sources

### 2. Replay Attacks

**Problem**: Attacker records encrypted packets, replays them later.

```
Time T1: Client sends "sudo rm -rf /tmp/cache"
         Packet: [nonce=1][encrypted command]

Time T2: Attacker replays exact packet
         Server executes command again
```

**Why this matters for terminals**:
- Replayed commands execute twice
- Could replay authentication sequences
- Timing attacks (replay at specific moment)

**Mitigations**:
1. **Sequence numbers**: Reject packets with seq ≤ last_seen
2. **Timestamps**: Reject packets outside time window
3. **Nonce tracking**: Remember recent nonces, reject duplicates
4. **Session binding**: Include session-specific data in nonce

**Mosh approach**:
```cpp
// 64-bit nonce includes sequence number
if (packet.seq <= expected_seq) {
    // Could be replay or out-of-order
    // Still process (idempotent) but don't update state
}
expected_seq = max(expected_seq, packet.seq + 1);
```

### 3. Session Hijacking

**Problem**: Without connection state, attacker can inject into session.

```
Legitimate client: 192.168.1.10
Attacker spoofs:   192.168.1.10

Server can't tell them apart if attacker knows:
- Server IP/port
- Session identifier
- Current sequence number (or can brute force)
```

**Why this matters for terminals**:
- Attacker could inject commands
- Could read session output (if bidirectional)
- Session persists indefinitely (unlike TCP timeout)

**Mitigations**:
1. **Authenticated encryption**: Every packet must have valid MAC
2. **High-entropy session key**: 128+ bits, established securely
3. **Sequence enforcement**: Tight window prevents brute force
4. **IP binding** (optional): Only accept from known IP (breaks roaming)

### 4. Denial of Service

**Problem**: UDP makes DoS easier than TCP.

**Attack vectors**:
| Attack | Description | Impact |
|--------|-------------|--------|
| **Flood** | Send millions of packets | CPU exhaustion parsing |
| **State exhaustion** | Create many fake sessions | Memory exhaustion |
| **Amplification** | Small request → large response | Bandwidth exhaustion |
| **Crypto DoS** | Force expensive crypto operations | CPU exhaustion |

**Mitigations**:
1. **Stateless cookies**: Don't allocate state until client proves reachability
2. **Rate limiting**: Per-IP and global limits
3. **Lightweight validation**: Check MAC before heavy processing
4. **Amplification limits**: Response ≤ request size until verified
5. **Proof of work**: Require client computation (controversial)

### 5. Key Exchange

**Problem**: How to establish shared secret without TCP?

**Options**:

| Method | Pros | Cons |
|--------|------|------|
| **SSH bootstrap** (mosh) | Proven security, existing infra | Requires TCP, extra round trip |
| **DTLS** | Standard, well-analyzed | Complex, certificate management |
| **Noise Protocol** | Modern, flexible | Less ecosystem support |
| **PSK** | Simple | Key distribution problem |
| **SRP/PAKE** | Password-based | Complex, timing attacks |

**Mosh approach**: SSH tunnel establishes AES key, passes via environment variable:
```bash
MOSH_KEY=base64_encoded_aes_key mosh-server new
# Client receives key from SSH stdout
```

**Tradeoffs**:
- Leverages SSH's proven auth (passwords, keys, certificates)
- Requires TCP connection (negates some UDP benefits)
- Key is session-specific (good for forward secrecy)

### 6. Port Exposure

**Problem**: Must listen on UDP port accessible from internet.

**Issues**:
- Firewall configuration required
- Port scanning reveals service
- Larger attack surface than SSH-only
- Corporate firewalls often block UDP

**Mosh approach**: Dynamic high port (60000-61000), communicated via SSH:
```
$ mosh user@server
# SSH connection establishes, server says:
MOSH CONNECT 60001 session_key_here
# Client connects to UDP/60001
```

**Security implications**:
- Port range must be open in firewall
- Random port provides slight obscurity (not security)
- Server must validate connections quickly (DoS risk)

### 7. Roaming vs Security Tradeoff

**Problem**: Roaming requires accepting packets from new IPs. But this enables hijacking.

```
Scenario 1: Legitimate roaming
  Client: 192.168.1.10 → 10.0.0.5 (WiFi to cellular)
  Server: Updates remote_addr, continues session

Scenario 2: Hijacking attempt
  Attacker: Sends packets from 10.0.0.99
  Server: If attacker has session key, accepts as new IP
```

**The fundamental tension**:
- **Strict IP binding**: Secure but breaks roaming
- **Accept any IP**: Roaming works but easier to hijack
- **Mosh compromise**: Accept new IP only with valid encrypted packet

**This is only safe if**:
- Session key is truly secret (not leaked, not brute-forceable)
- Encryption is authenticated (attacker can't forge packets)
- Sequence numbers prevent replay from old IP

---

## Designing a Secure UDP Protocol

### Phase 1: Bootstrap (over TCP/SSH)

```
┌─────────────────────────────────────────────────────────────┐
│  1. Client connects via SSH (existing infrastructure)       │
│                                                             │
│  2. Server generates:                                       │
│     - Session ID (128-bit random)                          │
│     - Session key (256-bit random)                         │
│     - UDP port (dynamic, high range)                       │
│                                                             │
│  3. Server sends to client via SSH stdout:                  │
│     RTACH_UDP <port> <base64(session_id)> <base64(key)>   │
│                                                             │
│  4. Client closes SSH, connects to UDP                      │
└─────────────────────────────────────────────────────────────┘
```

**Why SSH bootstrap**:
- Solves key exchange securely
- Reuses existing auth (keys, passwords, 2FA)
- Doesn't require PKI/certificates
- Proves client identity before allocating resources

### Phase 2: Initial UDP Handshake

```
Client                                  Server
   │                                      │
   │── ClientHello ──────────────────────>│
   │   [session_id][client_random]        │
   │   [timestamp][MAC]                   │
   │                                      │
   │<─────────────────── ServerHello ─────│
   │   [session_id][server_random]        │
   │   [client_random_echo][timestamp]    │
   │   [MAC]                              │
   │                                      │
   │── ClientConfirm ────────────────────>│
   │   [server_random_echo][MAC]          │
   │                                      │
   │<─────────────────── Ready ───────────│
   │                                      │
   │       Session established            │
```

**What this proves**:
- Client has session key (can create valid MAC)
- Client receives responses (echoed randoms)
- Not a replay (fresh randoms)
- IP is reachable (server can respond)

### Phase 3: Packet Format

```
┌─────────────────────────────────────────────────────────────┐
│ Packet Header (24 bytes)                                    │
├─────────────────────────────────────────────────────────────┤
│ Session ID    (16 bytes) - Which session this belongs to   │
│ Sequence      (8 bytes)  - Monotonic, includes direction   │
│   Bit 63: Direction (0=client→server, 1=server→client)     │
│   Bits 0-62: Counter                                        │
├─────────────────────────────────────────────────────────────┤
│ Encrypted Payload (AEAD: ChaCha20-Poly1305 or AES-GCM)     │
│ ├─ Timestamp (2 bytes)   - For RTT measurement             │
│ ├─ Timestamp Echo (2 bytes)                                 │
│ ├─ ACK info (8 bytes)    - State acknowledgment            │
│ └─ Data (variable)       - Terminal data or commands       │
├─────────────────────────────────────────────────────────────┤
│ Auth Tag (16 bytes)      - AEAD authentication tag         │
└─────────────────────────────────────────────────────────────┘
```

**Crypto choices**:
- **ChaCha20-Poly1305**: Fast on mobile (no AES-NI), constant-time
- **AES-256-GCM**: Hardware acceleration on modern CPUs
- **Nonce**: Derived from sequence number (never reuse with same key)

### Phase 4: Sequence Number Enforcement

```
Server maintains:
  expected_seq: u64 = 0
  window_bitmap: [64]bool  // Track recent out-of-order

On packet receive:
  if seq > expected_seq + 64:
      reject (too far ahead, possible attack)

  if seq < expected_seq - 64:
      reject (too old, possible replay)

  if seq in window_bitmap:
      reject (duplicate)

  mark seq in bitmap
  if seq >= expected_seq:
      expected_seq = seq + 1
      slide window
```

**Why 64-packet window**:
- Allows some reordering (UDP doesn't guarantee order)
- Limits replay window
- Memory-efficient (64 bits)

### Phase 5: Roaming Security

```
On packet from new IP:
  1. Verify session_id matches active session
  2. Verify AEAD tag (proves possession of key)
  3. Verify sequence is valid (not replay)
  4. If all pass: update client_addr, continue session

Additional protection (optional):
  - Require fresh handshake after IP change
  - Rate limit IP changes (max 1 per 10 seconds)
  - Log IP changes for audit
```

---

## Implementation Complexity

### What Mosh Does (Reference)

| Component | Lines of Code | Complexity |
|-----------|---------------|------------|
| Crypto (OCB mode) | ~800 | High - custom AEAD |
| Transport | ~1200 | Medium - fragmentation, state |
| Network | ~700 | Medium - socket handling |
| Total new code | ~2700 | Significant |

Plus dependencies on:
- OpenSSL (or similar)
- Protobuf
- zlib

### What rtach Would Need

| Component | Effort | Notes |
|-----------|--------|-------|
| Crypto | Low | Use std or zig-crypto, don't roll own |
| Key bootstrap | Low | Already have SSH, just pass key |
| Packet format | Medium | New wire format, versioning |
| Sequence tracking | Low | Bitmap, simple logic |
| Fragmentation | Medium | If supporting >MTU messages |
| State sync | High | If adding prediction/diffs |
| Testing | High | Security requires extensive testing |

---

## Risk Assessment

### Adding UDP to rtach

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Crypto implementation bug | Critical | Medium | Use vetted libraries only |
| Replay attack vulnerability | High | Low | Careful sequence enforcement |
| DoS amplification | Medium | Medium | Rate limiting, size limits |
| Session hijacking | Critical | Low | Strong keys, AEAD |
| Firewall blocks UDP | Low | High | Fall back to TCP |
| Increased attack surface | Medium | Certain | More code = more bugs |

### Recommendation

**For rtach, UDP is probably not worth it because**:

1. **SSH tunnel works**: TCP over SSH is proven, secure, works everywhere
2. **Prediction provides similar UX**: Client-side prediction reduces perceived latency without transport changes
3. **Roaming is rare on iOS**: Users typically reconnect manually anyway
4. **Complexity vs benefit**: Months of work for marginal improvement
5. **Security risk**: Custom UDP protocol is a liability

**When UDP might be worth it**:

1. **Very high packet loss** (>5%): Head-of-line blocking kills TCP
2. **Constant roaming**: VPN users, moving between networks frequently
3. **Extreme latency sensitivity**: Sub-50ms improvement matters
4. **LAN use case**: Trusted network, lower security requirements

---

## Alternative: QUIC

QUIC (HTTP/3's transport) provides many UDP benefits with less custom work:

| Feature | QUIC | Custom UDP |
|---------|------|------------|
| Encryption | Built-in TLS 1.3 | Roll your own |
| Multiplexing | Multiple streams | Single stream |
| Congestion control | Included | Roll your own |
| 0-RTT resumption | Yes | Custom session resume |
| Roaming | Connection ID based | Custom |
| Library support | Growing | None |

**QUIC for rtach**:
- Could use existing QUIC libraries
- Connection migration handles roaming
- Standard security model
- But: Still requires UDP port exposure, firewall issues

---

## Conclusion

Designing a secure UDP protocol is **doable but not trivial**. The main challenges:

1. **Key exchange**: Solved by SSH bootstrap (like mosh)
2. **Replay prevention**: Sequence numbers + window
3. **Spoofing**: Challenge-response handshake
4. **DoS**: Rate limiting, stateless cookies
5. **Roaming**: Accept new IP only with valid crypto

For rtach specifically:
- **Short term**: Focus on prediction, compression, RTT measurement within TCP
- **Medium term**: Consider QUIC if UDP benefits become critical
- **Avoid**: Rolling custom UDP protocol unless absolutely necessary

The security complexity is manageable, but the engineering effort and ongoing maintenance burden are significant for marginal latency improvement over a well-implemented prediction system.

---

## References

- [DTLS 1.3 RFC 9147](https://datatracker.ietf.org/doc/html/rfc9147)
- [Noise Protocol Framework](https://noiseprotocol.org/)
- [QUIC RFC 9000](https://datatracker.ietf.org/doc/html/rfc9000)
- [Mosh Security Analysis](https://mosh.org/mosh-paper.pdf) - Section 4
- [WireGuard Protocol](https://www.wireguard.com/protocol/) - Modern UDP crypto design
