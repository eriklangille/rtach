# Compression Strategy for rtach

Analysis of compression options for terminal data, with benchmarks and recommendations.

**Date**: January 2026

---

## Benchmark Results

Tested with synthetic terminal data (ANSI escapes, spaces, shell patterns) and editor output (cursor positioning).

### Terminal Output (Mixed ANSI, spaces, text)

| Strategy | 4KB Ratio | 16KB Ratio | 64KB Ratio |
|----------|-----------|------------|------------|
| zlib streaming level 6 | 60% | 57% | 57% |
| zlib frame 1024 level 6 | 67% | 66% | 67% |
| zlib frame 2048 level 6 | 63% | 62% | 63% |

### Editor Output (Cursor positioning, redraws)

| Strategy | 4KB Ratio | 16KB Ratio | 64KB Ratio |
|----------|-----------|------------|------------|
| zlib streaming level 6 | 13% | 7% | 3% |
| zlib frame 1024 level 6 | 20% | 19% | 19% |
| zlib frame 2048 level 6 | 16% | 16% | 16% |

Editor output compresses much better due to repetitive cursor sequences.

---

## Key Findings

### 1. Algorithm Comparison

| Algorithm | Speed | Ratio | Availability |
|-----------|-------|-------|--------------|
| **zlib/deflate** | Fast | Good | Zig std.compress.flate |
| zstd | Faster | Better | Requires C library |
| lzma | Very slow | Best | Not practical for real-time |

**Recommendation**: Use zlib (deflate). Available in Zig standard library, good balance of speed and compression.

### 2. Streaming vs Per-Frame

| Approach | Compression | Complexity | Reconnection |
|----------|-------------|------------|--------------|
| **Streaming** | 5-15% better | Dictionary state | Must replay all |
| **Per-frame** | Slightly worse | Stateless | Decompress any frame |

**Recommendation**: Per-frame compression. Simpler implementation, independent decompression allows partial replay on reconnection.

### 3. Optimal Frame Size

| Frame Size | Overhead | Latency | Ratio |
|------------|----------|---------|-------|
| 256 bytes | High | Low | Poor |
| 512 bytes | Medium | Low | Fair |
| **1024 bytes** | Low | Medium | Good |
| 2048 bytes | Low | Higher | Better |

**Recommendation**: 1024-2048 byte frames. Good balance between overhead and compression ratio.

### 4. Compression Level

| Level | Speed | Ratio Improvement |
|-------|-------|-------------------|
| **1 (fast)** | ~100 MB/s | Baseline |
| **6 (default)** | ~50 MB/s | ~5% better |
| 9 (best) | ~15 MB/s | ~1% better |

**Recommendation**: Level 6 (default) for typical use. Level 1 if latency is critical.

---

## Protocol Changes

### Current Format

```
Server→Client: [type:1B][len:4B][payload]
```

### Proposed Format

```
Server→Client: [flags:1B][type:1B][len:4B][payload]

Flags:
  bit 0: compressed (1) or raw (0)
  bit 1-7: reserved for future use
```

### Negotiation

Add compression capability to handshake:

```
Handshake: [magic:4B][version_major:1B][version_minor:1B][flags:2B]

Flags bit 0: supports compression
```

Server only sends compressed frames if client advertises support.

---

## Implementation Plan

### Phase 1: Add Compression Support

1. Add `flags` field to frame header
2. Implement `compressFrame()` using `std.compress.flate`
3. Add `decompressFrame()` for client
4. Only compress if result is smaller than original

### Phase 2: Negotiation

1. Add compression flag to handshake
2. Client advertises support in attach message
3. Server enables compression if both sides support

### Phase 3: Tuning

1. Measure real-world compression ratios
2. Adjust frame size based on data patterns
3. Consider adaptive compression level based on RTT

---

## Comparison to Mosh

| Aspect | Mosh | rtach |
|--------|------|-------|
| Algorithm | zlib | zlib (proposed) |
| Strategy | Streaming (4MB dictionary) | Per-frame (stateless) |
| What's compressed | Terminal state diffs | Raw PTY output |
| Reconnection | Replays from dictionary | Decompress any frame |

Mosh compresses diffs between terminal states, which is more efficient but requires maintaining full terminal state on server. rtach compresses raw PTY output, making per-frame compression more appropriate.

---

## Expected Savings

| Data Type | Compression Ratio | Savings |
|-----------|-------------------|---------|
| Typical terminal output | 60-70% | 30-40% bandwidth |
| Editor/TUI output | 15-25% | 75-85% bandwidth |
| `ls -la` directory listings | 40-50% | 50-60% bandwidth |
| Scrolling log output | 50-60% | 40-50% bandwidth |
| Binary data (cat image) | 95-100% | 0-5% bandwidth |

---

## Benchmark Tool

Run the benchmark:

```bash
cd rtach
uv run tools/compression_bench.py
```

For zstd comparison:
```bash
pip install zstandard
uv run tools/compression_bench.py
```
