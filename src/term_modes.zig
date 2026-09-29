const std = @import("std");
const testing = std.testing;

/// Tracks DEC private modes (ESC [ ? Pm h / l) in PTY output so a client that
/// attaches later can be put back into the same state.
///
/// On attach to an alternate-screen app, rtach skips the replay and only sends
/// SIGWINCH, so the app redraws but never re-sends the modes it set at startup.
/// Without restoring them, a TUI like Herdr kept rendering and taking keys but
/// stopped getting mouse clicks after the app was restarted.
///
/// Streaming: a sequence split across reads is carried over in the parser state.
pub const TermModes = struct {
    /// On/off modes restored on attach.
    /// The alternate screen (1049/47) is handled separately since it decides
    /// whether scrollback is replayed.
    const flag_modes = [_]u16{
        1, // DECCKM: application cursor keys
        1004, // focus in/out events
        2004, // bracketed paste
    };

    /// Mouse modes are two settings, not flags: which events are reported and how
    /// they're encoded. The last mode set wins and resetting any of them returns
    /// to the default (Ghostty and xterm work this way). Programs enable several:
    /// crossterm sets 1015 then 1006, so SGR is in effect, and restoring both in
    /// numeric order left urxvt encoding, which Herdr ignored.
    const mouse_event_modes = [_]u16{
        9, // X10: press only
        1000, // press/release
        1002, // button-event tracking (drag)
        1003, // any-event tracking (motion)
    };
    const mouse_format_modes = [_]u16{
        1005, // UTF-8 coordinates
        1006, // SGR
        1015, // urxvt
        1016, // SGR pixels
    };

    alt_screen: bool = false,
    cursor_visible: bool = true,
    /// Bit i set means flag_modes[i] is on
    flags: std.bit_set.IntegerBitSet(flag_modes.len) = .initEmpty(),
    mouse_event: ?u16 = null,
    mouse_format: ?u16 = null,

    state: State = .ground,
    params: [max_params]u16 = undefined,
    param_count: usize = 0,
    overflow: bool = false,

    const max_params = 16;
    const State = enum { ground, esc, csi, private };
    const ESC = 0x1b;

    pub fn process(self: *TermModes, data: []const u8) void {
        for (data) |b| self.step(b);
    }

    fn step(self: *TermModes, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == ESC) self.state = .esc;
            },
            .esc => self.state = if (b == '[') .csi else if (b == ESC) .esc else .ground,
            .csi => {
                if (b == '?') {
                    self.params[0] = 0;
                    self.param_count = 1;
                    self.overflow = false;
                    self.state = .private;
                } else {
                    // Not a private mode sequence; ESC restarts, anything else ends it
                    self.state = if (b == ESC) .esc else .ground;
                }
            },
            .private => switch (b) {
                '0'...'9' => {
                    if (self.overflow) return;
                    const p = &self.params[self.param_count - 1];
                    p.* = p.* *| 10 +| (b - '0');
                },
                ';' => {
                    if (self.param_count == max_params) {
                        self.overflow = true;
                    } else if (!self.overflow) {
                        self.params[self.param_count] = 0;
                        self.param_count += 1;
                    }
                },
                'h', 'l' => {
                    for (self.params[0..self.param_count]) |mode| self.apply(mode, b == 'h');
                    self.state = .ground;
                },
                ESC => self.state = .esc,
                else => self.state = .ground,
            },
        }
    }

    fn apply(self: *TermModes, mode: u16, on: bool) void {
        switch (mode) {
            1049, 1047, 47 => self.alt_screen = on,
            25 => self.cursor_visible = on,
            else => {
                if (std.mem.indexOfScalar(u16, &mouse_event_modes, mode) != null) {
                    self.mouse_event = if (on) mode else null;
                } else if (std.mem.indexOfScalar(u16, &mouse_format_modes, mode) != null) {
                    self.mouse_format = if (on) mode else null;
                } else if (std.mem.indexOfScalar(u16, &flag_modes, mode)) |i| {
                    self.flags.setValue(i, on);
                }
            },
        }
    }

    /// Longest possible output of `restoreSequence`
    pub const max_restore_len = blk: {
        var n: usize = "\x1b[?25l".len + 2 * "\x1b[?1000h".len;
        for (flag_modes) |m| n += std.fmt.count("\x1b[?{d}h", .{m});
        break :blk n;
    };

    /// Escape sequences that put a fresh terminal into the tracked modes
    /// (excluding the alternate screen). Returns an empty slice if everything
    /// is at its default.
    pub fn restoreSequence(self: *const TermModes, buf: *[max_restore_len]u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var it = self.flags.iterator(.{});
        while (it.next()) |i| w.print("\x1b[?{d}h", .{flag_modes[i]}) catch unreachable;
        if (self.mouse_event) |m| w.print("\x1b[?{d}h", .{m}) catch unreachable;
        if (self.mouse_format) |m| w.print("\x1b[?{d}h", .{m}) catch unreachable;
        if (!self.cursor_visible) w.writeAll("\x1b[?25l") catch unreachable;
        return w.buffered();
    }
};

fn expectRestore(m: *const TermModes, expected: []const u8) !void {
    var buf: [TermModes.max_restore_len]u8 = undefined;
    try testing.expectEqualStrings(expected, m.restoreSequence(&buf));
}

test "default state restores nothing" {
    var m: TermModes = .{};
    m.process("hello \x1b[1mworld\x1b[0m\r\n");
    try expectRestore(&m, "");
    try testing.expect(!m.alt_screen);
    try testing.expect(m.cursor_visible);
}

test "tracks alt screen and cursor visibility" {
    var m: TermModes = .{};
    m.process("\x1b[?1049h\x1b[?25l");
    try testing.expect(m.alt_screen);
    try testing.expect(!m.cursor_visible);
    try expectRestore(&m, "\x1b[?25l");
    m.process("\x1b[?1049l\x1b[?25h");
    try testing.expect(!m.alt_screen);
    try testing.expect(m.cursor_visible);
}

test "crossterm mouse capture restores the modes in effect" {
    var m: TermModes = .{};
    // EnableMouseCapture: the last event mode (any) and format (SGR) win
    m.process("\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1015h\x1b[?1006h");
    try expectRestore(&m, "\x1b[?1003h\x1b[?1006h");
    m.process("\x1b[?1006l\x1b[?1015l\x1b[?1003l\x1b[?1002l\x1b[?1000l");
    try expectRestore(&m, "");
}

test "resetting any mouse mode returns it to the default" {
    var m: TermModes = .{};
    m.process("\x1b[?1002h\x1b[?1006h\x1b[?1000l\x1b[?1015l");
    try expectRestore(&m, "");
}

test "multiple params in one sequence" {
    var m: TermModes = .{};
    m.process("\x1b[?1000;1006;2004h");
    try expectRestore(&m, "\x1b[?2004h\x1b[?1000h\x1b[?1006h");
    m.process("\x1b[?1000;1006l");
    try expectRestore(&m, "\x1b[?2004h");
}

test "sequence split across reads" {
    var m: TermModes = .{};
    const seq = "ab\x1b[?1049;1002hcd\x1b[?25l";
    for (seq) |b| m.process(&.{b});
    try testing.expect(m.alt_screen);
    try expectRestore(&m, "\x1b[?1002h\x1b[?25l");
}

test "non-private CSI and ESC restart are handled" {
    var m: TermModes = .{};
    // CSI 1000 h (ANSI mode, not DEC private) is ignored
    m.process("\x1b[1000h");
    try expectRestore(&m, "");
    // ESC interrupting a sequence starts a new one
    m.process("\x1b[?100\x1b[?1006h");
    try expectRestore(&m, "\x1b[?1006h");
}

test "too many params does not overflow" {
    var m: TermModes = .{};
    m.process("\x1b[?1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1004h");
    try expectRestore(&m, "\x1b[?1h");
}

test "max_restore_len fits everything" {
    var m: TermModes = .{};
    m.process("\x1b[?1;1004;2004;1000;1016h\x1b[?25l");
    var buf: [TermModes.max_restore_len]u8 = undefined;
    try testing.expectEqual(TermModes.max_restore_len, m.restoreSequence(&buf).len);
}
