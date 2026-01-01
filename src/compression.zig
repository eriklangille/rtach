const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("zlib.h");
});

pub const Error = error{
    CompressionFailed,
    DecompressionFailed,
    OutputBufferTooSmall,
};

/// Compress data using raw deflate (no zlib header/trailer).
/// This produces RFC 1951 format compatible with Apple's Compression framework.
/// Returns the compressed length, or null if compression didn't reduce size.
/// Output buffer should be at least input.len + 16 bytes to handle worst case.
pub fn compress(input: []const u8, output: []u8) Error!?usize {
    if (input.len == 0) return null;

    var stream: c.z_stream = .{
        .next_in = @constCast(input.ptr),
        .avail_in = @intCast(input.len),
        .next_out = output.ptr,
        .avail_out = @intCast(output.len),
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Use -15 window bits for raw deflate (no zlib header/trailer)
    // This is compatible with Apple's COMPRESSION_ZLIB
    var result = c.deflateInit2(
        &stream,
        6, // compression level (Z_DEFAULT_COMPRESSION equivalent)
        c.Z_DEFLATED,
        -15, // negative = raw deflate, 15 = window size
        8, // memory level
        c.Z_DEFAULT_STRATEGY,
    );
    if (result != c.Z_OK) return Error.CompressionFailed;
    defer _ = c.deflateEnd(&stream);

    result = c.deflate(&stream, c.Z_FINISH);
    if (result != c.Z_STREAM_END) return Error.CompressionFailed;

    const compressed_len: usize = @intCast(stream.total_out);

    // Only return compressed data if it's actually smaller
    if (compressed_len >= input.len) return null;

    return compressed_len;
}

/// Decompress raw deflate data (no zlib header/trailer).
/// Output buffer should be large enough for decompressed data.
pub fn decompress(input: []const u8, output: []u8) Error!usize {
    if (input.len == 0) return 0;

    var stream: c.z_stream = .{
        .next_in = @constCast(input.ptr),
        .avail_in = @intCast(input.len),
        .next_out = output.ptr,
        .avail_out = @intCast(output.len),
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Use -15 window bits for raw deflate (no zlib header/trailer)
    var result = c.inflateInit2(&stream, -15);
    if (result != c.Z_OK) return Error.DecompressionFailed;
    defer _ = c.inflateEnd(&stream);

    result = c.inflate(&stream, c.Z_FINISH);
    if (result != c.Z_STREAM_END) {
        if (result == c.Z_BUF_ERROR) return Error.OutputBufferTooSmall;
        return Error.DecompressionFailed;
    }

    return @intCast(stream.total_out);
}

/// Compress data, writing to a provided buffer.
/// Returns a slice of the compressed data, or the original data if compression didn't help.
/// The `compressed` flag is set to true if compression was used.
pub fn compressOrPassthrough(
    input: []const u8,
    output: []u8,
    compressed: *bool,
) []const u8 {
    compressed.* = false;

    if (input.len < 64) {
        // Don't bother compressing small data - overhead not worth it
        return input;
    }

    if (output.len < input.len) {
        // Output buffer too small, skip compression
        return input;
    }

    const result = compress(input, output) catch {
        return input;
    };

    if (result) |compressed_len| {
        compressed.* = true;
        return output[0..compressed_len];
    }

    return input;
}

// Protocol integration constants
pub const COMPRESSION_FLAG: u8 = 0x80;

/// Check if a response type byte has the compression flag set
pub fn isCompressed(type_byte: u8) bool {
    return (type_byte & COMPRESSION_FLAG) != 0;
}

/// Get the actual response type, stripping the compression flag
pub fn getResponseType(type_byte: u8) u8 {
    return type_byte & ~COMPRESSION_FLAG;
}

/// Set the compression flag on a response type
pub fn setCompressed(type_byte: u8) u8 {
    return type_byte | COMPRESSION_FLAG;
}

// Tests
test "compress and decompress roundtrip" {
    // Test data with repetitive content (compresses well)
    const input = "Hello, World! " ** 100; // 1400 bytes of repetitive data

    var compressed: [2048]u8 = undefined;
    const comp_len = (try compress(input, &compressed)).?;

    // Should compress significantly
    try testing.expect(comp_len < input.len / 2);

    var decompressed: [2048]u8 = undefined;
    const decomp_len = try decompress(compressed[0..comp_len], &decompressed);

    try testing.expectEqual(input.len, decomp_len);
    try testing.expectEqualStrings(input, decompressed[0..decomp_len]);
}

test "compress returns null for incompressible data" {
    // Random-ish data that doesn't compress well
    var input: [100]u8 = undefined;
    for (&input, 0..) |*b, i| {
        b.* = @truncate(i *% 7 +% 13);
    }

    var compressed: [200]u8 = undefined;
    const result = try compress(&input, &compressed);

    // Should return null since compression doesn't help
    try testing.expect(result == null);
}

test "compress returns null for small data" {
    const input = "hi";
    var compressed: [100]u8 = undefined;

    var was_compressed: bool = undefined;
    const output = compressOrPassthrough(input, &compressed, &was_compressed);

    try testing.expect(!was_compressed);
    try testing.expectEqualStrings(input, output);
}

test "compression flag operations" {
    try testing.expect(!isCompressed(0x00));
    try testing.expect(!isCompressed(0x7F));
    try testing.expect(isCompressed(0x80));
    try testing.expect(isCompressed(0xFF));

    try testing.expectEqual(@as(u8, 0x00), getResponseType(0x00));
    try testing.expectEqual(@as(u8, 0x00), getResponseType(0x80));
    try testing.expectEqual(@as(u8, 0x7F), getResponseType(0xFF));

    try testing.expectEqual(@as(u8, 0x80), setCompressed(0x00));
    try testing.expectEqual(@as(u8, 0x85), setCompressed(0x05));
}

test "terminal data compression" {
    // Simulate realistic terminal output with ANSI escapes
    const input =
        "\x1b[0m\x1b[32muser@host\x1b[0m:\x1b[34m~/projects\x1b[0m$ ls -la\r\n" ++
        "total 48\r\n" ++
        "drwxr-xr-x  12 user user 4096 Jan  1 12:00 .\r\n" ++
        "drwxr-xr-x   5 user user 4096 Jan  1 12:00 ..\r\n" ++
        "-rw-r--r--   1 user user  220 Jan  1 12:00 .bashrc\r\n" ++
        "-rw-r--r--   1 user user  807 Jan  1 12:00 .profile\r\n" ++
        "drwxr-xr-x   8 user user 4096 Jan  1 12:00 .git\r\n" ++
        "drwxr-xr-x   2 user user 4096 Jan  1 12:00 src\r\n" ++
        "-rw-r--r--   1 user user 1234 Jan  1 12:00 Makefile\r\n" ++
        "\x1b[0m\x1b[32muser@host\x1b[0m:\x1b[34m~/projects\x1b[0m$ ";

    var compressed: [1024]u8 = undefined;
    const comp_len = (try compress(input, &compressed)).?;

    // Terminal output should compress reasonably well (lots of repeated patterns)
    const ratio = @as(f64, @floatFromInt(comp_len)) / @as(f64, @floatFromInt(input.len));
    try testing.expect(ratio < 0.8); // At least 20% reduction

    // Verify roundtrip
    var decompressed: [1024]u8 = undefined;
    const decomp_len = try decompress(compressed[0..comp_len], &decompressed);
    try testing.expectEqualStrings(input, decompressed[0..decomp_len]);
}
