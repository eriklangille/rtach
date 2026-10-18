//! What's happening in a session, for the app's pane titles, status and notifications:
//! the program in front, its directory, and an agent's state.
//!
//! The master probes the foreground process every second or so (`probe`). Agent state
//! comes from the agent's hooks (`clauntty agent-state`, a `state;` line on the
//! command pipe), with the terminal title as a fallback for Claude Code. Its task is the
//! last prompt the user sent it (a `task;` line from the same hook). The master
//! writes it all to `<socket>.state` as one JSON line and sends the same line to the
//! app as `pane;<id>;<json>`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Agent = enum { none, claude };

pub const Status = enum {
    /// No agent in the session
    none,
    /// An agent waiting for a prompt
    idle,
    working,
    /// Waiting on the user (a permission prompt, a question)
    blocked,
    /// Finished its turn
    done,
};

pub const PaneState = struct {
    fg: [64]u8 = undefined,
    fg_len: usize = 0,
    cwd: [1024]u8 = undefined,
    cwd_len: usize = 0,
    agent: Agent = .none,
    status: Status = .none,
    note: [256]u8 = undefined,
    note_len: usize = 0,
    /// The last prompt sent to the agent, tidied (`taskFromPrompt`)
    task: [task_max]u8 = undefined,
    task_len: usize = 0,
    /// Set by a hook: then the title doesn't override the status
    from_hook: bool = false,

    pub fn fgName(self: *const PaneState) []const u8 {
        return self.fg[0..self.fg_len];
    }

    pub fn cwdPath(self: *const PaneState) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    pub fn noteText(self: *const PaneState) []const u8 {
        return self.note[0..self.note_len];
    }

    pub fn taskText(self: *const PaneState) []const u8 {
        return self.task[0..self.task_len];
    }

    /// An agent pane's name, as the app titles it: the conversation's name from Claude
    /// Code's title (after its spinner or "✳"), else the task, else "Claude"
    pub fn agentLabel(self: *const PaneState, title: []const u8) []const u8 {
        const fallback = if (self.task_len > 0) self.taskText() else "Claude";
        const view = std.unicode.Utf8View.init(title) catch return fallback;
        var it = view.iterator();
        const first = it.nextCodepoint() orelse return fallback;
        if (first < 0x2000) return fallback;
        const topic = std.mem.trim(u8, title[it.i..], " ");
        if (topic.len == 0 or std.mem.eql(u8, topic, "Claude Code")) return fallback;
        return topic;
    }

    /// Record the agent's task. True if it changed.
    pub fn setTask(self: *PaneState, task: []const u8) bool {
        const n = @min(task.len, self.task.len);
        if (std.mem.eql(u8, self.taskText(), task[0..n])) return false;
        @memcpy(self.task[0..n], task[0..n]);
        self.task_len = n;
        return true;
    }

    /// Record the foreground process. True if anything changed.
    pub fn setForeground(self: *PaneState, fg: []const u8, cwd: []const u8) bool {
        const fg_n = @min(fg.len, self.fg.len);
        const cwd_n = @min(cwd.len, self.cwd.len);
        if (std.mem.eql(u8, self.fgName(), fg[0..fg_n]) and std.mem.eql(u8, self.cwdPath(), cwd[0..cwd_n])) return false;
        @memcpy(self.fg[0..fg_n], fg[0..fg_n]);
        self.fg_len = fg_n;
        @memcpy(self.cwd[0..cwd_n], cwd[0..cwd_n]);
        self.cwd_len = cwd_n;
        return true;
    }

    /// A hook's `state;<status>;<note>` (status "end": the agent exited). True if
    /// anything changed.
    pub fn applyHook(self: *PaneState, status_name: []const u8, note: []const u8) bool {
        const before = self.*;
        if (std.mem.eql(u8, status_name, "end")) {
            self.agent = .none;
            self.status = .none;
            self.from_hook = false;
            self.task_len = 0;
        } else {
            const status = std.meta.stringToEnum(Status, status_name) orelse return false;
            self.agent = .claude;
            self.status = status;
            self.from_hook = true;
            // A new session (or /clear) starts idle, with nothing asked yet
            if (status == .idle) self.task_len = 0;
        }
        const n = @min(note.len, self.note.len);
        @memcpy(self.note[0..n], note[0..n]);
        self.note_len = if (self.status == .blocked) n else 0;
        return !std.meta.eql(before.agent, self.agent) or before.status != self.status or
            !std.mem.eql(u8, before.note[0..before.note_len], self.noteText()) or before.task_len != self.task_len;
    }

    /// Claude Code's title, when no hook reports: a spinner first means working, "✳"
    /// means waiting. True if anything changed.
    pub fn applyTitle(self: *PaneState, title: []const u8) bool {
        if (self.from_hook) return false;
        const status: ?Status = if (std.mem.startsWith(u8, title, "✳"))
            .idle
        else if (startsWithSpinner(title))
            .working
        else
            null;
        const s = status orelse {
            if (self.agent == .none) return false;
            self.agent = .none;
            self.status = .none;
            return true;
        };
        if (self.agent == .claude and self.status == s) return false;
        self.agent = .claude;
        self.status = s;
        return true;
    }

    /// One JSON line, for the .state file and the app
    pub fn writeJson(self: *const PaneState, writer: *std.Io.Writer, title: []const u8) !void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("v");
        try jw.write(1);
        try jw.objectField("fg");
        try jw.write(self.fgName());
        try jw.objectField("cwd");
        try jw.write(self.cwdPath());
        try jw.objectField("title");
        try jw.write(title);
        try jw.objectField("agent");
        try jw.write(@tagName(self.agent));
        try jw.objectField("state");
        try jw.write(@tagName(self.status));
        if (self.note_len > 0) {
            try jw.objectField("note");
            try jw.write(self.noteText());
        }
        if (self.task_len > 0) {
            try jw.objectField("task");
            try jw.write(self.taskText());
        }
        // This master sends push notifications (2.18.0), so the app doesn't post its own
        try jw.objectField("pushes");
        try jw.write(true);
        try jw.endObject();
    }
};

/// The longest task kept (bytes)
pub const task_max = 120;

/// A prompt as a task for a title: its first line with text, without the `[Image #1]` and
/// `[Pasted text #1 +20 lines]` placeholders Claude Code puts in, spaces collapsed,
/// cut to `task_max` bytes on a character boundary. Empty for a slash command
/// (`/clear`, `/compact`), which isn't a task.
pub fn taskFromPrompt(prompt: []const u8, out: *[task_max]u8) []const u8 {
    var len: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    var started = false;
    while (i < prompt.len) {
        const c = prompt[i];
        if (c == '[' and isPlaceholder(prompt[i + 1 ..])) {
            const close = std.mem.indexOfScalarPos(u8, prompt, i, ']') orelse prompt.len - 1;
            i = close + 1;
            pending_space = started;
            continue;
        }
        if (c == '\n' or c == '\r') {
            // The first line with text is the task
            if (started) break;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t') {
            pending_space = started;
            i += 1;
            continue;
        }
        if (!started and c == '/') return out[0..0];
        // Whole characters only
        const char_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const extra: usize = if (pending_space) 1 else 0;
        if (len + extra + char_len > out.len or i + char_len > prompt.len) break;
        if (pending_space) out[len] = ' ';
        len += extra;
        @memcpy(out[len .. len + char_len], prompt[i .. i + char_len]);
        len += char_len;
        i += char_len;
        started = true;
        pending_space = false;
    }
    return out[0..len];
}

fn isPlaceholder(rest: []const u8) bool {
    return std.mem.startsWith(u8, rest, "Image #") or std.mem.startsWith(u8, rest, "Pasted text");
}

/// Braille spinner (U+2800 block) or the half circles Claude Code also uses
fn startsWithSpinner(title: []const u8) bool {
    const view = std.unicode.Utf8View.init(title) catch return false;
    var it = view.iterator();
    const first = it.nextCodepoint() orelse return false;
    return (first >= 0x2800 and first <= 0x28FF) or (first >= 0x25D0 and first <= 0x25D3);
}

// MARK: Foreground process

extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;

pub const Foreground = struct { name: []const u8, cwd: []const u8 };

/// The foreground process of the terminal on `pty_master`: its name and directory
pub fn probe(pty_master: posix.fd_t, name_buf: []u8, cwd_buf: []u8) ?Foreground {
    const pgid = tcgetpgrp(pty_master);
    if (pgid <= 0) return null;
    switch (builtin.os.tag) {
        .macos => return probeDarwin(pgid, name_buf, cwd_buf),
        .linux => return probeLinux(pgid, name_buf, cwd_buf),
        else => return null,
    }
}

extern "c" fn proc_name(pid: c_int, buffer: [*]u8, size: u32) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;

/// sys/proc_info.h: PROC_PIDVNODEPATHINFO gives a proc_vnodepathinfo, whose first
/// member is the cwd's vnode_info_path: a 152-byte vnode_info, then the path
const PROC_PIDVNODEPATHINFO = 9;
const vnode_info_size = 152;
const vnode_info_path_size = vnode_info_size + std.posix.PATH_MAX;

fn probeDarwin(pid: posix.pid_t, name_buf: []u8, cwd_buf: []u8) ?Foreground {
    const n = proc_name(pid, name_buf.ptr, @intCast(name_buf.len));
    if (n <= 0) return null;
    var info: [2 * vnode_info_path_size]u8 align(8) = undefined;
    const got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, info.len);
    var cwd: []const u8 = "";
    if (got == info.len) {
        const path = info[vnode_info_size..vnode_info_path_size];
        const len = std.mem.indexOfScalar(u8, path, 0) orelse path.len;
        const m = @min(len, cwd_buf.len);
        @memcpy(cwd_buf[0..m], path[0..m]);
        cwd = cwd_buf[0..m];
    }
    return .{ .name = name_buf[0..@intCast(n)], .cwd = cwd };
}

fn probeLinux(pid: posix.pid_t, name_buf: []u8, cwd_buf: []u8) ?Foreground {
    var path_buf: [64]u8 = undefined;
    const comm_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const fd = std.c.open(comm_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, name_buf.ptr, name_buf.len);
    if (n <= 0) return null;
    const name = std.mem.trimEnd(u8, name_buf[0..@intCast(n)], "\n");
    const cwd_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/cwd", .{pid}) catch return null;
    const len = std.c.readlink(cwd_path, cwd_buf.ptr, cwd_buf.len);
    return .{ .name = name, .cwd = if (len > 0) cwd_buf[0..@intCast(len)] else "" };
}

// MARK: Tests

const testing = std.testing;

test "hooks set the status; the title only counts without them" {
    var s: PaneState = .{};
    try testing.expect(s.applyTitle("⠋ Fixing the login redirect"));
    try testing.expectEqual(Status.working, s.status);
    try testing.expect(s.applyTitle("✳ Fixing the login redirect"));
    try testing.expectEqual(Status.idle, s.status);

    try testing.expect(s.applyHook("blocked", "Claude needs your permission to use Bash"));
    try testing.expectEqual(Status.blocked, s.status);
    try testing.expectEqualStrings("Claude needs your permission to use Bash", s.noteText());
    try testing.expect(!s.applyTitle("⠋ Fixing"));
    try testing.expectEqual(Status.blocked, s.status);

    try testing.expect(s.applyHook("done", ""));
    try testing.expectEqual(@as(usize, 0), s.note_len);
    try testing.expect(!s.applyHook("done", ""));
    try testing.expect(s.applyHook("end", ""));
    try testing.expectEqual(Agent.none, s.agent);
}

test "the task is the last prompt; a new session clears it" {
    var s: PaneState = .{};
    _ = s.applyHook("working", "");
    try testing.expect(s.setTask("Fix the login redirect"));
    try testing.expect(!s.setTask("Fix the login redirect"));
    _ = s.applyHook("done", "");
    try testing.expectEqualStrings("Fix the login redirect", s.taskText());
    try testing.expect(s.applyHook("idle", ""));
    try testing.expectEqual(@as(usize, 0), s.task_len);
}

test "prompts as tasks" {
    var buf: [task_max]u8 = undefined;
    try testing.expectEqualStrings("shouldnt it exist with a terminal pane?", taskFromPrompt("[Image #30] shouldnt it exist with a terminal pane?", &buf));
    try testing.expectEqualStrings("fix this", taskFromPrompt("\n  fix   this\nand more lines", &buf));
    try testing.expectEqualStrings("see and this", taskFromPrompt("see [Pasted text #1 +20 lines] and this", &buf));
    try testing.expectEqualStrings("", taskFromPrompt("/compact keep the plan", &buf));
    try testing.expectEqualStrings("", taskFromPrompt("[Image #1]", &buf));
    // Cut on a character boundary
    const long = "é" ** 100;
    const cut = taskFromPrompt(long, &buf);
    try testing.expectEqual(@as(usize, task_max), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "a plain title clears a title-detected agent" {
    var s: PaneState = .{};
    _ = s.applyTitle("✳ Claude Code");
    try testing.expect(s.applyTitle("~/src"));
    try testing.expectEqual(Agent.none, s.agent);
}

test "agent label" {
    var p: PaneState = .{};
    try std.testing.expectEqualStrings("Claude", p.agentLabel("✳ Claude Code"));
    _ = p.setTask("fix the build");
    try std.testing.expectEqualStrings("fix the build", p.agentLabel("✳ Claude Code"));
    try std.testing.expectEqualStrings("fix the build", p.agentLabel("zsh"));
    try std.testing.expectEqualStrings("Refactor login", p.agentLabel("⠂ Refactor login"));
}

test "json line" {
    var s: PaneState = .{};
    _ = s.setForeground("zsh", "/src/app");
    _ = s.applyHook("blocked", "needs \"you\"");
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeJson(&w, "✳ Fix it");
    try testing.expectEqualStrings(
        \\{"v":1,"fg":"zsh","cwd":"/src/app","title":"✳ Fix it","agent":"claude","state":"blocked","note":"needs \"you\"","pushes":true}
    , w.buffered());
}

test "probe finds this test's foreground process" {
    // Needs a terminal; skipped when tests run without one
    if (std.c.isatty(0) != 1) return error.SkipZigTest;
    var name: [64]u8 = undefined;
    var cwd: [1024]u8 = undefined;
    const got = probe(0, &name, &cwd) orelse return error.SkipZigTest;
    try testing.expect(got.name.len > 0);
}
