const std = @import("std");
const testing = std.testing;

/// Tracks the terminal state programs set in PTY output, so a client that attaches
/// later can be put back into it: DEC private modes (ESC [ ? Pm h / l), the kitty
/// keyboard protocol's flags, xterm's modifyOtherKeys, the keypad mode and the cursor
/// style.
///
/// On attach to an alternate-screen app, rtach skips the replay and only sends
/// SIGWINCH, so the app redraws but never re-sends the modes it set at startup.
/// Without restoring them, a TUI like Herdr kept rendering and taking keys but
/// stopped getting mouse clicks after the app was restarted. A program on the normal
/// screen set them before the replay's cut: Claude Code pushes kitty keyboard flags
/// (`ESC [ > 5 u`) and sets modifyOtherKeys (`ESC [ > 4 ; 2 m`) once at startup, so
/// after a reattach the terminal sent the older key encodings.
///
/// Not tracked: the scroll region and origin mode (they depend on the size, which an
/// attach can change), colors, charsets, tab stops, a saved cursor.
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
        2031, // color scheme change reports (Claude Code follows the theme)
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
    /// Autowrap (?7), on by default
    autowrap: bool = true,
    /// Inside a synchronized update (?2026h, until ?2026l): a frame being drawn. Not
    /// restored on attach: only says whether a redraw is finished.
    sync_frame: bool = false,
    /// Bit i set means flag_modes[i] is on
    flags: std.bit_set.IntegerBitSet(flag_modes.len) = .initEmpty(),
    mouse_event: ?u16 = null,
    mouse_format: ?u16 = null,
    /// The keypad's application mode (DECKPAM `ESC =`, DECKPNM `ESC >`)
    keypad_app: bool = false,
    /// The kitty keyboard flags of each screen: Ghostty keeps a stack per screen, and
    /// switching screens doesn't reset them
    kitty_main: KittyStack = .{},
    kitty_alt: KittyStack = .{},
    /// xterm's key modifier options (modifyOtherKeys and kin); null: the default
    modify_keys: ?ModifyKeys = null,
    /// DECSCUSR (`ESC [ Ps SP q`); 0 is the terminal's default
    cursor_style: u8 = 0,

    state: State = .ground,
    /// `?`, `>`, `<` or `=` right after the CSI, else 0
    prefix: u8 = 0,
    /// The last intermediate byte (0x20–0x2f, e.g. the space in DECSCUSR), else 0
    intermediate: u8 = 0,
    params: [max_params]u16 = undefined,
    param_count: usize = 0,
    overflow: bool = false,

    const max_params = 16;
    const State = enum { ground, esc, csi };
    const ESC = 0x1b;
    /// The last `ESC [ > Pp ; Pv m` (modifyOtherKeys being Pp 4), or `ESC [ > n`
    pub const ModifyKeys = struct {
        option: u8 = 4,
        value: ?u16 = null,
        /// `ESC [ > n` (Ghostty's "numeric except" format)
        except: bool = false,
    };

    /// The kitty keyboard protocol's flags, as Ghostty keeps them: 8 entries, `idx`
    /// the current one, a push past the end evicting the oldest
    pub const KittyStack = struct {
        flags: [8]u8 = @splat(0),
        idx: u3 = 0,

        pub fn current(self: KittyStack) u8 {
            return self.flags[self.idx];
        }

        /// `ESC [ = flags ; mode u`: 1 sets, 2 adds, 3 clears
        fn set(self: *KittyStack, mode: u16, v: u8) void {
            switch (mode) {
                1 => self.flags[self.idx] = v,
                2 => self.flags[self.idx] |= v,
                3 => self.flags[self.idx] &= ~v,
                else => {},
            }
        }

        fn push(self: *KittyStack, v: u8) void {
            self.idx +%= 1;
            self.flags[self.idx] = v;
        }

        fn pop(self: *KittyStack, n: u16) void {
            if (n >= self.flags.len) {
                self.* = .{};
                return;
            }
            for (0..n) |_| {
                self.flags[self.idx] = 0;
                self.idx -%= 1;
            }
        }

        /// Longest output of `restore`: the base, then 7 pushes
        pub const max_restore_len = "\x1b[=31;1u".len + 7 * "\x1b[>31u".len;

        /// Puts a fresh terminal's stack (base 0, nothing pushed) into this one. A
        /// stack that overflowed comes back without the evicted entries.
        fn restore(self: KittyStack, w: *std.Io.Writer) void {
            if (self.flags[0] != 0) w.print("\x1b[={d};1u", .{self.flags[0]}) catch unreachable;
            var i: u4 = 1;
            while (i <= self.idx) : (i += 1) w.print("\x1b[>{d}u", .{self.flags[i]}) catch unreachable;
        }
    };

    pub fn process(self: *TermModes, data: []const u8) void {
        for (data) |b| self.step(b);
    }

    fn kitty(self: *TermModes) *KittyStack {
        return if (self.alt_screen) &self.kitty_alt else &self.kitty_main;
    }

    fn step(self: *TermModes, b: u8) void {
        switch (self.state) {
            .ground => {
                if (b == ESC) self.state = .esc;
            },
            .esc => switch (b) {
                '[' => {
                    self.prefix = 0;
                    self.intermediate = 0;
                    self.param_count = 0;
                    self.overflow = false;
                    self.state = .csi;
                },
                '=' => {
                    self.keypad_app = true;
                    self.state = .ground;
                },
                '>' => {
                    self.keypad_app = false;
                    self.state = .ground;
                },
                // RIS: the terminal is back to its defaults
                'c' => self.* = .{},
                ESC => {},
                else => self.state = .ground,
            },
            .csi => switch (b) {
                '?', '>', '<', '=' => {
                    // A prefix only right after the CSI
                    if (self.param_count == 0 and self.prefix == 0 and self.intermediate == 0) {
                        self.prefix = b;
                    } else {
                        self.state = .ground;
                    }
                },
                '0'...'9' => {
                    if (self.param_count == 0) self.startParam();
                    if (self.overflow) return;
                    const p = &self.params[self.param_count - 1];
                    p.* = p.* *| 10 +| (b - '0');
                },
                ';', ':' => {
                    if (self.param_count == 0) self.startParam();
                    self.startParam();
                },
                0x20...0x2f => self.intermediate = b,
                0x40...0x7e => {
                    self.dispatch(b);
                    self.state = .ground;
                },
                ESC => self.state = .esc,
                // C0 controls inside a sequence are executed and don't end it
                0x00...0x1a, 0x1c...0x1f => {},
                else => self.state = .ground,
            },
        }
    }

    fn startParam(self: *TermModes) void {
        if (self.param_count == max_params) {
            self.overflow = true;
        } else if (!self.overflow) {
            self.params[self.param_count] = 0;
            self.param_count += 1;
        }
    }

    /// The `i`th parameter, or `default` when there isn't one
    fn param(self: *const TermModes, i: usize, default: u16) u16 {
        return if (i < self.param_count) self.params[i] else default;
    }

    fn dispatch(self: *TermModes, final: u8) void {
        const params = self.params[0..self.param_count];
        switch (self.prefix) {
            '?' => if (self.intermediate == 0 and (final == 'h' or final == 'l')) {
                for (params) |mode| self.apply(mode, final == 'h');
            },
            // Kitty keyboard flags are 5 bits; Ghostty ignores anything larger
            '>' => switch (final) {
                'u' => if (self.param_count <= 1 and self.param(0, 0) <= 31) self.kitty().push(@intCast(self.param(0, 0))),
                'm' => self.modifyKeys(params),
                'n' => self.modify_keys = .{ .except = true },
                else => {},
            },
            '<' => if (final == 'u') self.kitty().pop(if (self.param_count == 1) params[0] else 1),
            '=' => if (final == 'u' and self.param(0, 0) <= 31) self.kitty().set(self.param(1, 1), @intCast(self.param(0, 0))),
            0 => if (final == 'q' and self.intermediate == ' ') {
                self.cursor_style = @intCast(@min(self.param(0, 0), 255));
            },
            else => {},
        }
    }

    /// `ESC [ > Pp ; Pv m`, as Ghostty takes it: no parameters (or Pp 0) is the
    /// default; Pp 1, 2 and 4 set a format. modifyOtherKeys off (Pp 4, no Pv or 0)
    /// counts as the default too.
    fn modifyKeys(self: *TermModes, params: []const u16) void {
        if (params.len == 0 or params[0] == 0 or (params[0] == 4 and (params.len == 1 or params[1] == 0))) {
            self.modify_keys = null;
            return;
        }
        if (params.len > 2) return;
        switch (params[0]) {
            1, 2, 4 => self.modify_keys = .{ .option = @intCast(params[0]), .value = if (params.len == 2) params[1] else null },
            else => {},
        }
    }

    fn apply(self: *TermModes, mode: u16, on: bool) void {
        switch (mode) {
            1049, 1047, 47 => self.alt_screen = on,
            25 => self.cursor_visible = on,
            7 => self.autowrap = on,
            2026 => self.sync_frame = on,
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
        var n: usize = "\x1b[?25l".len + "\x1b[?7l".len + 2 * "\x1b[?1000h".len + "\x1b=".len +
            "\x1b[>4;65535m".len + "\x1b[255 q".len + KittyStack.max_restore_len;
        for (flag_modes) |m| n += std.fmt.count("\x1b[?{d}h", .{m});
        break :blk n;
    };

    /// Escape sequences that put a fresh terminal into the tracked state, on the screen
    /// it's on (excluding the alternate screen switch itself; see
    /// `mainScreenRestore`). Returns an empty slice if everything is at its default.
    pub fn restoreSequence(self: *const TermModes, buf: *[max_restore_len]u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var it = self.flags.iterator(.{});
        while (it.next()) |i| w.print("\x1b[?{d}h", .{flag_modes[i]}) catch unreachable;
        if (self.mouse_event) |m| w.print("\x1b[?{d}h", .{m}) catch unreachable;
        if (self.mouse_format) |m| w.print("\x1b[?{d}h", .{m}) catch unreachable;
        if (!self.autowrap) w.writeAll("\x1b[?7l") catch unreachable;
        if (self.keypad_app) w.writeAll("\x1b=") catch unreachable;
        if (self.modify_keys) |k| {
            if (k.except) {
                w.writeAll("\x1b[>4n") catch unreachable;
            } else if (k.value) |v| {
                w.print("\x1b[>{d};{d}m", .{ k.option, v }) catch unreachable;
            } else {
                w.print("\x1b[>{d}m", .{k.option}) catch unreachable;
            }
        }
        if (self.cursor_style != 0) w.print("\x1b[{d} q", .{self.cursor_style}) catch unreachable;
        (if (self.alt_screen) self.kitty_alt else self.kitty_main).restore(&w);
        if (!self.cursor_visible) w.writeAll("\x1b[?25l") catch unreachable;
        return w.buffered();
    }

    /// On the alternate screen, the main screen's kitty keyboard flags, for before the
    /// switch to it: they're back when the program leaves it
    pub fn mainScreenRestore(self: *const TermModes, buf: *[KittyStack.max_restore_len]u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.alt_screen) self.kitty_main.restore(&w);
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
    m.process("\x1b[?1;1004;2004;2031;1000;1016h\x1b[?25l\x1b[?7l\x1b=\x1b[>4;65535m\x1b[255 q");
    m.process("\x1b[=31;1u");
    for (0..7) |_| m.process("\x1b[>31u");
    var buf: [TermModes.max_restore_len]u8 = undefined;
    try testing.expectEqual(TermModes.max_restore_len, m.restoreSequence(&buf).len);
}

test "Claude Code's keyboard modes come back" {
    var m: TermModes = .{};
    // What it sends at startup, the kitty query answered
    m.process("\x1b[?2004h\x1b[?1004h\x1b[?2031h\x1b[?u\x1b[>5u\x1b[>4;2m\x1b[>0q");
    try expectRestore(&m, "\x1b[?1004h\x1b[?2004h\x1b[?2031h\x1b[>4;2m\x1b[>5u");
    // And at exit
    m.process("\x1b[<u\x1b[>4m\x1b[?2004l\x1b[?1004l\x1b[?2031l");
    try expectRestore(&m, "");
}

test "kitty keyboard stack: push, pop, set" {
    var m: TermModes = .{};
    m.process("\x1b[>1u\x1b[>3u");
    try testing.expectEqual(@as(u8, 3), m.kitty_main.current());
    try expectRestore(&m, "\x1b[>1u\x1b[>3u");
    // Pop one (no parameter: one)
    m.process("\x1b[<u");
    try expectRestore(&m, "\x1b[>1u");
    // Set on the current entry: or, then clear a bit
    m.process("\x1b[=4;2u");
    try testing.expectEqual(@as(u8, 5), m.kitty_main.current());
    m.process("\x1b[=1;3u");
    try testing.expectEqual(@as(u8, 4), m.kitty_main.current());
    // Pop past the bottom: everything goes
    m.process("\x1b[<20u");
    try expectRestore(&m, "");
    // The base set without a push
    m.process("\x1b[=9u");
    try expectRestore(&m, "\x1b[=9;1u");
    // Flags past 5 bits are ignored, as Ghostty does
    m.process("\x1b[>99u");
    try expectRestore(&m, "\x1b[=9;1u");
}

test "each screen has its own kitty stack" {
    var m: TermModes = .{};
    m.process("\x1b[>5u\x1b[?1049h\x1b[>1u");
    try testing.expectEqual(@as(u8, 1), m.kitty_alt.current());
    try expectRestore(&m, "\x1b[>1u");
    var buf: [TermModes.KittyStack.max_restore_len]u8 = undefined;
    try testing.expectEqualStrings("\x1b[>5u", m.mainScreenRestore(&buf));
    // Back on the main screen, its own flags
    m.process("\x1b[?1049l");
    try expectRestore(&m, "\x1b[>5u");
    try testing.expectEqualStrings("", m.mainScreenRestore(&buf));
}

test "modifyOtherKeys and the other key modifier options" {
    var m: TermModes = .{};
    m.process("\x1b[>4;1m");
    try expectRestore(&m, "\x1b[>4;1m");
    m.process("\x1b[>4n");
    try expectRestore(&m, "\x1b[>4n");
    m.process("\x1b[>m");
    try expectRestore(&m, "");
    m.process("\x1b[>2m");
    try expectRestore(&m, "\x1b[>2m");
    m.process("\x1b[>0m");
    try expectRestore(&m, "");
    // Other CSI > queries aren't settings
    m.process("\x1b[>0q\x1b[>c");
    try expectRestore(&m, "");
}

test "keypad mode, autowrap and cursor style" {
    var m: TermModes = .{};
    m.process("\x1b=\x1b[?7l\x1b[5 q");
    try expectRestore(&m, "\x1b[?7l\x1b=\x1b[5 q");
    m.process("\x1b>\x1b[?7h\x1b[0 q");
    try expectRestore(&m, "");
    // A plain `CSI 5 q` isn't DECSCUSR
    m.process("\x1b[5q");
    try expectRestore(&m, "");
}

test "a full reset clears everything" {
    var m: TermModes = .{};
    m.process("\x1b[?1049h\x1b[?2004h\x1b[>5u\x1b[>4;2m\x1b=");
    m.process("\x1bc");
    try testing.expect(!m.alt_screen);
    try expectRestore(&m, "");
}

test "new sequences split across reads" {
    var m: TermModes = .{};
    const seq = "x\x1b[>5uy\x1b[>4;2mz\x1b[6 q";
    for (seq) |b| m.process(&.{b});
    try expectRestore(&m, "\x1b[>4;2m\x1b[6 q\x1b[>5u");
}
