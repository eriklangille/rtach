const std = @import("std");
const testing = std.testing;

/// Removes terminal queries from PTY output before it is stored for replay.
///
/// Stored output is only ever replayed (attach, resume flush, redraw), so any query
/// in it (cursor position, device attributes, mode or color reports) is stale. A
/// client's terminal would answer it anyway and the answer lands in the program's
/// input: Codex showed "[6;1R[7;1R" in its prompt after a reconnect.
///
/// Streaming: a sequence split across reads is held until it completes. Queries
/// are short, so a sequence longer than `max_pending` is passed through untouched.
pub const QueryFilter = struct {
    pub const max_pending = 64;

    state: State = .ground,
    kind: Kind = .csi,
    pending: [max_pending]u8 = undefined,
    pending_len: usize = 0,

    const State = enum { ground, esc, seq, seq_esc, passthrough, passthrough_esc };
    const Kind = enum { csi, osc, dcs };

    const ESC = 0x1b;
    const BEL = 0x07;

    /// Filter `input` into `out` and return the filtered bytes.
    /// `out` must hold at least `input.len + max_pending` bytes.
    pub fn process(self: *QueryFilter, input: []const u8, out: []u8) []u8 {
        std.debug.assert(out.len >= input.len + max_pending);
        var n: usize = 0;
        for (input) |b| self.step(b, out, &n);
        return out[0..n];
    }

    fn step(self: *QueryFilter, b: u8, out: []u8, n: *usize) void {
        switch (self.state) {
            .ground => {
                if (b == ESC) {
                    self.start(b);
                } else {
                    emit(out, n, b);
                }
            },
            .esc => {
                const kind: ?Kind = switch (b) {
                    '[' => .csi,
                    ']' => .osc,
                    'P' => .dcs,
                    else => null,
                };
                if (kind) |k| {
                    self.kind = k;
                    self.hold(b);
                    self.state = .seq;
                } else {
                    // Not a sequence we filter: pass ESC through and reprocess b
                    self.flush(out, n);
                    self.step(b, out, n);
                }
            },
            .seq => switch (self.kind) {
                .csi => {
                    if (b == ESC or b == 0x18 or b == 0x1a) {
                        // Aborted by ESC/CAN/SUB
                        self.flush(out, n);
                        self.step(b, out, n);
                    } else if (b >= 0x40 and b <= 0x7e) {
                        self.hold(b);
                        self.finish(out, n);
                    } else {
                        self.holdOrPassthrough(b, out, n);
                    }
                },
                .osc, .dcs => {
                    if (b == BEL and self.kind == .osc) {
                        self.hold(b);
                        self.finish(out, n);
                    } else if (b == ESC) {
                        self.holdOrPassthrough(b, out, n);
                        if (self.state == .seq) self.state = .seq_esc;
                    } else {
                        self.holdOrPassthrough(b, out, n);
                    }
                },
            },
            .seq_esc => {
                if (b == '\\') {
                    self.hold(b);
                    self.finish(out, n);
                } else {
                    // ESC ended the string and starts something new: keep the string,
                    // then reprocess from that ESC
                    self.pending_len -= 1;
                    self.flush(out, n);
                    self.start(ESC);
                    self.step(b, out, n);
                }
            },
            .passthrough => {
                emit(out, n, b);
                switch (self.kind) {
                    .csi => if (b >= 0x40 and b <= 0x7e) {
                        self.state = .ground;
                    },
                    .osc, .dcs => if (b == BEL and self.kind == .osc) {
                        self.state = .ground;
                    } else if (b == ESC) {
                        self.state = .passthrough_esc;
                    },
                }
            },
            .passthrough_esc => {
                if (b == '\\') {
                    emit(out, n, b);
                    self.state = .ground;
                } else {
                    // The ESC (already emitted) started a new sequence
                    self.state = .esc;
                    self.pending[0] = ESC;
                    self.pending_len = 1;
                    // The ESC was already emitted; drop it from pending so it isn't doubled
                    n.* -= 1;
                    self.step(b, out, n);
                }
            },
        }
    }

    fn emit(out: []u8, n: *usize, b: u8) void {
        out[n.*] = b;
        n.* += 1;
    }

    fn start(self: *QueryFilter, b: u8) void {
        self.pending[0] = b;
        self.pending_len = 1;
        self.state = .esc;
    }

    fn hold(self: *QueryFilter, b: u8) void {
        self.pending[self.pending_len] = b;
        self.pending_len += 1;
    }

    fn holdOrPassthrough(self: *QueryFilter, b: u8, out: []u8, n: *usize) void {
        if (self.pending_len < max_pending) {
            self.hold(b);
            return;
        }
        // Too long to be a query: emit what we held and stream the rest
        self.flush(out, n);
        self.state = .passthrough;
        self.step(b, out, n);
    }

    fn flush(self: *QueryFilter, out: []u8, n: *usize) void {
        @memcpy(out[n.*..][0..self.pending_len], self.pending[0..self.pending_len]);
        n.* += self.pending_len;
        self.pending_len = 0;
        self.state = .ground;
    }

    fn finish(self: *QueryFilter, out: []u8, n: *usize) void {
        if (isQuery(self.kind, self.pending[0..self.pending_len])) {
            self.pending_len = 0;
            self.state = .ground;
        } else {
            self.flush(out, n);
        }
    }

    /// Whether a complete sequence (starting with ESC) asks the terminal to reply
    fn isQuery(kind: Kind, seq: []const u8) bool {
        switch (kind) {
            .csi => {
                const body = seq[2..];
                const final = body[body.len - 1];
                const params = body[0 .. body.len - 1];
                const prefix: u8 = if (params.len > 0 and std.mem.indexOfScalar(u8, "?<=>", params[0]) != null) params[0] else 0;
                var has_dollar = false;
                var has_intermediate = false;
                for (params) |c| {
                    if (c >= 0x20 and c <= 0x2f) has_intermediate = true;
                    if (c == '$') has_dollar = true;
                }
                return switch (final) {
                    'n' => true, // DSR: cursor position, status
                    'c' => !has_intermediate, // DA1/DA2/DA3
                    'p' => has_dollar, // DECRQM
                    'u' => prefix == '?', // kitty keyboard flags
                    'q' => prefix == '>', // XTVERSION
                    't' => prefix == 0 and isReportingWindowOp(params),
                    else => false,
                };
            },
            .osc => {
                // OSC 4/10/11/12/52... with "?" asks for the current value
                const end: usize = if (seq[seq.len - 1] == BEL) seq.len - 1 else seq.len - 2;
                const payload = seq[2..end];
                return payload.len > 0 and payload[payload.len - 1] == '?';
            },
            .dcs => {
                const payload = seq[2..];
                return std.mem.startsWith(u8, payload, "$q") or // DECRQSS
                    std.mem.startsWith(u8, payload, "+q"); // XTGETTCAP
            },
        }
    }

    /// XTWINOPS that report state (sizes, position, title)
    fn isReportingWindowOp(params: []const u8) bool {
        const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
        const op = std.fmt.parseInt(u16, params[0..end], 10) catch return false;
        return switch (op) {
            11, 13, 14, 15, 16, 18, 19, 20, 21 => true,
            else => false,
        };
    }
};

fn filterAll(input: []const u8, buf: []u8) []u8 {
    var f: QueryFilter = .{};
    return f.process(input, buf);
}

test "drops cursor position and device attribute queries" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("ab", filterAll("a\x1b[6nb", &buf));
    try testing.expectEqualStrings("ab", filterAll("a\x1b[?6nb", &buf));
    try testing.expectEqualStrings("", filterAll("\x1b[c\x1b[>c\x1b[0c", &buf));
    try testing.expectEqualStrings("", filterAll("\x1b[?2026$p\x1b[?u\x1b[>q\x1b[18t", &buf));
}

test "drops OSC color queries and DCS requests" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("x", filterAll("\x1b]11;?\x07x", &buf));
    try testing.expectEqualStrings("x", filterAll("\x1b]10;?\x1b\\x", &buf));
    try testing.expectEqualStrings("x", filterAll("\x1bP$qm\x1b\\x", &buf));
    try testing.expectEqualStrings("x", filterAll("\x1bP+q544e\x1b\\x", &buf));
}

test "keeps ordinary sequences" {
    var buf: [256]u8 = undefined;
    const keep = "\x1b[1;31mred\x1b[0m\x1b[2J\x1b[?1049h\x1b[?25l\x1b]0;title\x07\x1b[2 q\x1b[>1u\x1b[22;0t\x1b(B\x1b7";
    try testing.expectEqualStrings(keep, filterAll(keep, &buf));
}

test "handles sequences split across reads" {
    var f: QueryFilter = .{};
    var buf: [128]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for ([_][]const u8{ "a\x1b", "[", "6", "nb\x1b[3", "1mc\x1b]11", ";?", "\x1b", "\\d" }) |part| {
        try out.appendSlice(testing.allocator, f.process(part, &buf));
    }
    try testing.expectEqualStrings("ab\x1b[31mcd", out.items);
}

test "passes long strings through untouched" {
    var buf: [512]u8 = undefined;
    const long = "\x1b]52;c;" ++ "QUJD" ** 40 ++ "\x07after";
    try testing.expectEqualStrings(long, filterAll(long, &buf));
    const long_st = "\x1b]0;" ++ "t" ** 100 ++ "\x1b\\after\x1b[6n";
    try testing.expectEqualStrings("\x1b]0;" ++ "t" ** 100 ++ "\x1b\\after", filterAll(long_st, &buf));
}

test "ESC inside a string starts a new sequence" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("\x1b]0;t\x1b[1mx", filterAll("\x1b]0;t\x1b[1mx", &buf));
    try testing.expectEqualStrings("\x1b]0;tx", filterAll("\x1b]0;t\x1b[6nx", &buf));
}
