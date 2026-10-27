//! `clauntty review`: hand a code change to the app as a review, then wait for the
//! user's comments.
//!
//! Claude writes only its judgement (notes.json: priorities, comments); this runs git
//! and bundles the diff, the full old and new contents of each file (the app highlights
//! whole files, not hunks) and the notes into ~/.clauntty/reviews/<id>.json, which the
//! app downloads. When the user sends, the app writes their comments to <id>.reply;
//! this prints them and exits, which wakes the agent that started it as a background
//! command. If this is gone by then, the app types them into the pane instead.
//!
//! Files like lockfiles, generated or minified ones and very large ones come without
//! their contents or diff, only their line counts, the way GitHub collapses them.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");
const inbox = @import("inbox.zig");

/// Reviews older than this are deleted the next time one is made
pub const max_age_ms: i64 = 24 * std.time.ms_per_hour;
/// Bigger than this, a file comes collapsed, without contents or diff
const max_file_bytes: usize = 512 * 1024;
/// Untracked files past this many are only counted
const max_untracked = 50;
/// How often the reply is looked for
const poll_ms = 200;

const File = struct {
    path: []const u8,
    /// Its path before a rename
    old_path: ?[]const u8 = null,
    /// added, modified, deleted, renamed, untracked
    status: []const u8,
    old: ?[]const u8 = null,
    new: ?[]const u8 = null,
    added: ?u32 = null,
    removed: ?u32 = null,
    /// Why there are no contents and no diff: large, binary, generated, lockfile, minified
    skipped: ?[]const u8 = null,
};

const Bundle = struct {
    version: u32 = 1,
    id: []const u8,
    /// The pane that ran the command: comments go there if this is gone
    pane: []const u8,
    repo: []const u8,
    base: []const u8,
    /// What's compared, said plainly: `HEAD~1 (e5301ec) → HEAD (493fa38)`
    range: []const u8,
    /// Against the working tree (untracked files are part of the change)
    working_tree: bool,
    notes: std.json.Value,
    diff: []const u8,
    files: []const File,
    /// Untracked files past `max_untracked`
    untracked_more: usize,
};

pub const Made = struct {
    id: []const u8,
    dir: []const u8,
    files: usize,
};

const usage = "usage: clauntty review <notes.json> [--repo DIR] [--base REF]";

/// Write the bundle. Errors are printed; null after one.
pub fn make(arena: std.mem.Allocator, io: std.Io, args: []const []const u8, pane: []const u8) ?Made {
    var notes_path: ?[]const u8 = null;
    var repo_arg: []const u8 = ".";
    var base_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "--base")) {
            if (i + 1 == args.len) return fail("{s}", .{usage});
            i += 1;
            if (arg[2] == 'r') repo_arg = args[i] else base_arg = args[i];
        } else if (notes_path == null and !std.mem.startsWith(u8, arg, "-")) {
            notes_path = arg;
        } else return fail("{s}", .{usage});
    }
    const path = notes_path orelse return fail("{s}", .{usage});

    const notes_text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err|
        return fail("{s}: {s}", .{ path, @errorName(err) });
    const notes = std.json.parseFromSliceLeaky(std.json.Value, arena, notes_text, .{}) catch
        return fail("{s}: not valid JSON", .{path});
    if (notes != .object) return fail("{s}: not a JSON object", .{path});

    const repo_out = git(arena, io, repo_arg, &.{ "rev-parse", "--show-toplevel" }) orelse
        return fail("not in a git repository: {s}", .{repo_arg});
    const repo = std.mem.trimEnd(u8, repo_out, "\n");

    const base = base_arg orelse if (notes.object.get("base")) |b| switch (b) {
        .string => |s| if (std.mem.trim(u8, s, " ").len > 0) std.mem.trim(u8, s, " ") else "HEAD",
        else => "HEAD",
    } else "HEAD";
    const range = Range.parse(arena, io, repo, base) orelse return fail("unknown ref: {s}", .{base});

    // MARK: Files

    var files: std.ArrayList(File) = .empty;
    const name_status = git(arena, io, repo, &.{ "-c", "core.quotePath=false", "diff", "--name-status", "-z", "--find-renames", base, "--" }) orelse
        return fail("git diff {s} failed", .{base});
    var fields = std.mem.splitScalar(u8, name_status, 0);
    while (fields.next()) |code| {
        if (code.len == 0) continue;
        const first = fields.next() orelse break;
        var file: File = .{ .path = first, .status = "modified" };
        switch (code[0]) {
            'A' => file.status = "added",
            'D' => file.status = "deleted",
            'R', 'C' => {
                file.status = "renamed";
                file.old_path = first;
                file.path = fields.next() orelse break;
            },
            else => {},
        }
        files.append(arena, file) catch return oom();
    }

    var untracked_more: usize = 0;
    if (range.new == null) {
        const out = git(arena, io, repo, &.{ "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z" }) orelse "";
        var names = std.mem.splitScalar(u8, out, 0);
        var count: usize = 0;
        while (names.next()) |name| {
            if (name.len == 0) continue;
            count += 1;
            if (count > max_untracked) continue;
            files.append(arena, .{ .path = name, .status = "untracked" }) catch return oom();
        }
        untracked_more = count -| max_untracked;
    }

    const generated = generatedPaths(arena, io, repo, files.items);
    for (files.items) |*file| {
        if (lockfile(file.path)) {
            file.skipped = "lockfile";
        } else if (minified(file.path)) {
            file.skipped = "minified";
        } else if (generated.contains(file.path)) {
            file.skipped = "generated";
        }
        if (!std.mem.eql(u8, file.status, "added") and !std.mem.eql(u8, file.status, "untracked")) {
            const spec = std.fmt.allocPrint(arena, "{s}:{s}", .{ range.old, file.old_path orelse file.path }) catch return oom();
            file.old = content(arena, io, repo, spec, file);
        }
        if (!std.mem.eql(u8, file.status, "deleted")) {
            if (range.new) |new| {
                const spec = std.fmt.allocPrint(arena, "{s}:{s}", .{ new, file.path }) catch return oom();
                file.new = content(arena, io, repo, spec, file);
            } else {
                file.new = worktreeContent(arena, io, repo, file);
            }
        }
        // Counted from the contents: numstat has no untracked files, and a file skipped for
        // its name was still read for this
        if (std.mem.eql(u8, file.status, "untracked")) {
            if (file.new) |text| {
                file.added = lineCount(text);
                file.removed = 0;
            }
        }
        if (file.skipped != null) {
            file.old = null;
            file.new = null;
        }
    }
    countLines(arena, io, repo, base, files.items);

    // MARK: Diff

    var diff: std.ArrayList(u8) = .empty;
    {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(arena, &.{ "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--find-renames", "-U3", base, "--", "." }) catch return oom();
        for (files.items) |file| {
            if (file.skipped == null or std.mem.eql(u8, file.status, "untracked")) continue;
            argv.append(arena, std.fmt.allocPrint(arena, ":(exclude,literal){s}", .{file.path}) catch return oom()) catch return oom();
            if (file.old_path) |old| argv.append(arena, std.fmt.allocPrint(arena, ":(exclude,literal){s}", .{old}) catch return oom()) catch return oom();
        }
        const out = git(arena, io, repo, argv.items) orelse return fail("git diff {s} failed", .{base});
        diff.appendSlice(arena, out) catch return oom();
    }
    for (files.items) |file| {
        if (!std.mem.eql(u8, file.status, "untracked") or file.skipped != null) continue;
        const out = gitCodes(arena, io, repo, &.{ "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", file.path }, 1) orelse continue;
        diff.appendSlice(arena, out) catch return oom();
    }

    // MARK: Write

    const home = sys.getenv("HOME") orelse return fail("HOME is not set", .{});
    const dir = std.fmt.allocPrint(arena, "{s}/.clauntty/reviews", .{home}) catch return oom();
    const now_ms: i64 = @intCast(@divFloor(sys.realtimeNs(), std.time.ns_per_ms));
    prune(io, dir, now_ms);

    var id_buf: [64]u8 = undefined;
    const id = arena.dupe(u8, inbox.makeId(&id_buf, now_ms, std.c.getpid(), 0)) catch return oom();
    const bundle: Bundle = .{
        .id = id,
        .pane = pane,
        .repo = repo,
        .base = base,
        .range = range.describe(arena, io, repo),
        .working_tree = range.new == null,
        .notes = notes,
        .diff = diff.items,
        .files = files.items,
        .untracked_more = untracked_more,
    };
    const json = std.json.Stringify.valueAlloc(arena, bundle, .{ .emit_null_optional_fields = false }) catch return oom();

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch |err| return fail("{s}: {s}", .{ dir, @errorName(err) });
    const tmp = std.fmt.allocPrint(arena, "{s}/.{s}.tmp", .{ dir, id }) catch return oom();
    const final = std.fmt.allocPrint(arena, "{s}/{s}.json", .{ dir, id }) catch return oom();
    cwd.writeFile(io, .{ .sub_path = tmp, .data = json, .flags = .{ .permissions = .fromMode(0o600) } }) catch |err|
        return fail("{s}: {s}", .{ tmp, @errorName(err) });
    cwd.rename(tmp, cwd, final, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return fail("{s}: {s}", .{ final, @errorName(err) });
    };
    return .{ .id = id, .dir = dir, .files = files.items.len };
}

/// Wait for the app's reply, print it and clean up. Taking the reply is a rename, so
/// the app can tell whether it arrived (`<id>.reply` gone) or nobody took it.
pub fn wait(arena: std.mem.Allocator, io: std.Io, made: Made) u8 {
    const cwd = std.Io.Dir.cwd();
    const bundle = std.fmt.allocPrint(arena, "{s}/{s}.json", .{ made.dir, made.id }) catch return 1;
    const reply = std.fmt.allocPrint(arena, "{s}/{s}.reply", .{ made.dir, made.id }) catch return 1;
    const taken = std.fmt.allocPrint(arena, "{s}/{s}.taken", .{ made.dir, made.id }) catch return 1;
    while (true) {
        if (cwd.rename(reply, cwd, taken, io)) |_| {
            const text = cwd.readFileAlloc(io, taken, arena, .limited(4 * 1024 * 1024)) catch "";
            writeOut(text);
            if (text.len > 0 and text[text.len - 1] != '\n') writeOut("\n");
            cwd.deleteFile(io, taken) catch {};
            cwd.deleteFile(io, bundle) catch {};
            return 0;
        } else |_| {}
        // Deleted: answered on another device, or pruned
        if (cwd.access(io, bundle, .{})) |_| {} else |_| {
            writeOut("The review was closed without comments.\n");
            return 0;
        }
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch return 1;
    }
}

// MARK: Range

/// The two sides compared: `a..b` (or `a...b`, from where they meet) compares two commits;
/// anything else, that ref against the working tree
const Range = struct {
    old: []const u8,
    new: ?[]const u8,
    old_name: []const u8,

    fn parse(arena: std.mem.Allocator, io: std.Io, repo: []const u8, base: []const u8) ?Range {
        var range: Range = .{ .old = base, .new = null, .old_name = base };
        if (std.mem.indexOf(u8, base, "..")) |at| {
            const three = std.mem.startsWith(u8, base[at..], "...");
            const a = if (at == 0) "HEAD" else base[0..at];
            const rest = base[at + @as(usize, if (three) 3 else 2) ..];
            const b = if (rest.len == 0) "HEAD" else rest;
            range = .{ .old = a, .new = b, .old_name = a };
            if (three) {
                const out = git(arena, io, repo, &.{ "merge-base", a, b }) orelse return null;
                range.old = std.mem.trimEnd(u8, out, "\n");
            }
        }
        if (!isCommit(arena, io, repo, range.old)) return null;
        if (range.new) |new| if (!isCommit(arena, io, repo, new)) return null;
        return range;
    }

    fn describe(self: Range, arena: std.mem.Allocator, io: std.Io, repo: []const u8) []const u8 {
        const old = named(arena, io, repo, self.old_name);
        if (self.new) |new| return std.fmt.allocPrint(arena, "{s} → {s}", .{ old, named(arena, io, repo, new) }) catch new;
        if (std.mem.eql(u8, self.old_name, "HEAD")) return std.fmt.allocPrint(arena, "Uncommitted changes on {s}", .{old}) catch old;
        return std.fmt.allocPrint(arena, "Working tree against {s}", .{old}) catch old;
    }
};

fn isCommit(arena: std.mem.Allocator, io: std.Io, repo: []const u8, ref: []const u8) bool {
    const spec = std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) catch return false;
    return git(arena, io, repo, &.{ "rev-parse", "--verify", "--quiet", spec }) != null;
}

/// `ref (abc1234)`, or the short hash alone when the ref is one
fn named(arena: std.mem.Allocator, io: std.Io, repo: []const u8, ref: []const u8) []const u8 {
    const spec = std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) catch return ref;
    const out = git(arena, io, repo, &.{ "rev-parse", "--short", spec }) orelse return ref;
    const sha = std.mem.trimEnd(u8, out, "\n");
    if (std.mem.startsWith(u8, ref, sha)) return sha;
    return std.fmt.allocPrint(arena, "{s} ({s})", .{ ref, sha }) catch ref;
}

// MARK: Contents

/// `git show <rev>:<path>`, or null with the file marked skipped when it's too large,
/// binary or not UTF-8
fn content(arena: std.mem.Allocator, io: std.Io, repo: []const u8, spec: []const u8, file: *File) ?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = &.{ gitPath(arena, io), "-C", repo, "show", spec },
        .environ_map = environment(arena),
        .stdout_limit = .limited(max_file_bytes),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        if (err == error.StreamTooLong) file.skipped = file.skipped orelse "large";
        return null;
    };
    if (result.term != .exited or result.term.exited != 0) return null;
    return checked(result.stdout, file);
}

fn worktreeContent(arena: std.mem.Allocator, io: std.Io, repo: []const u8, file: *File) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ repo, file.path }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| {
        if (err == error.StreamTooLong) file.skipped = file.skipped orelse "large";
        return null;
    };
    return checked(text, file);
}

fn checked(text: []const u8, file: *File) ?[]const u8 {
    const head = text[0..@min(text.len, 8000)];
    if (std.mem.indexOfScalar(u8, head, 0) != null or !std.unicode.utf8ValidateSlice(text)) {
        file.skipped = file.skipped orelse "binary";
        return null;
    }
    return text;
}

fn lineCount(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

/// +/− per tracked file, from `git diff --numstat -z`: `added\tremoved\tpath\0`, or for
/// a rename `added\tremoved\t\0old\0new\0`. Binary files have `-` for both.
fn countLines(arena: std.mem.Allocator, io: std.Io, repo: []const u8, base: []const u8, files: []File) void {
    const out = git(arena, io, repo, &.{ "-c", "core.quotePath=false", "diff", "--numstat", "-z", "--find-renames", base, "--" }) orelse return;
    var records = std.mem.splitScalar(u8, out, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        var parts = std.mem.splitScalar(u8, record, '\t');
        const added = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch null;
        const removed = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch null;
        var path = parts.rest();
        if (path.len == 0) {
            _ = records.next(); // the old path
            path = records.next() orelse break;
        }
        for (files) |*file| {
            if (!std.mem.eql(u8, file.path, path) or std.mem.eql(u8, file.status, "untracked")) continue;
            file.added = added;
            file.removed = removed;
        }
    }
}

// MARK: Collapsed files

/// Files marked `linguist-generated` in .gitattributes
fn generatedPaths(arena: std.mem.Allocator, io: std.Io, repo: []const u8, files: []const File) std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    if (files.len == 0) return set;
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "check-attr", "-z", "linguist-generated", "--" }) catch return set;
    for (files) |file| argv.append(arena, file.path) catch return set;
    const out = git(arena, io, repo, argv.items) orelse return set;
    // path\0attribute\0value\0
    var fields = std.mem.splitScalar(u8, out, 0);
    while (fields.next()) |path| {
        _ = fields.next() orelse break;
        const value = fields.next() orelse break;
        if (std.mem.eql(u8, value, "set") or std.mem.eql(u8, value, "true")) set.put(arena, path, {}) catch {};
    }
    return set;
}

fn lockfile(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    const names = [_][]const u8{
        "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",    "pnpm-lock.yaml", "bun.lock",      "bun.lockb",
        "Cargo.lock",        "Gemfile.lock",        "poetry.lock",  "uv.lock",        "Pipfile.lock",  "composer.lock",
        "go.sum",            "Package.resolved",    "Podfile.lock", "flake.lock",     "mix.lock",      "pubspec.lock",
        "gradle.lockfile",   "packages.lock.json",  "deno.lock",    "Cartfile.resolved",
    };
    for (names) |known| if (std.mem.eql(u8, name, known)) return true;
    return false;
}

fn minified(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    for ([_][]const u8{ ".min.js", ".min.css", ".min.mjs", ".map" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

// MARK: Housekeeping

/// Delete reviews older than `max_age_ms`: their bundles, replies and anything else of theirs
fn prune(io: std.Io, dir_path: []const u8, now_ms: i64) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var stale_buf: [64][96]u8 = undefined;
    var stale_lens: [64]usize = undefined;
    var stale_count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file or entry.name.len == 0 or entry.name[0] == '.') continue;
        const id_end = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;
        const created = inbox.idTime(entry.name[0..id_end]) orelse continue;
        if (now_ms - created <= max_age_ms) continue;
        if (entry.name.len > stale_buf[0].len or stale_count == stale_buf.len) continue;
        @memcpy(stale_buf[stale_count][0..entry.name.len], entry.name);
        stale_lens[stale_count] = entry.name.len;
        stale_count += 1;
    }
    for (0..stale_count) |i| dir.deleteFile(io, stale_buf[i][0..stale_lens[i]]) catch {};
}

// MARK: Helpers

/// git's output, or null if it failed
fn git(arena: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) ?[]const u8 {
    return gitCodes(arena, io, repo, args, 0);
}

/// git's output when it exits 0 or `also_ok` (`diff --no-index` exits 1 for a difference)
fn gitCodes(arena: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8, also_ok: u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ gitPath(arena, io), "-C", repo }) catch return null;
    argv.appendSlice(arena, args) catch return null;
    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .environ_map = environment(arena),
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    return switch (result.term) {
        .exited => |code| if (code == 0 or code == also_ok) result.stdout else null,
        else => null,
    };
}

/// This process's environment for git (its children otherwise get the Io's, which is
/// empty: no HOME, so no ~/.gitconfig and its excludes)
var environ_map: ?std.process.Environ.Map = null;

fn environment(arena: std.mem.Allocator) ?*const std.process.Environ.Map {
    if (environ_map == null) {
        var map = std.process.Environ.Map.init(arena);
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const text = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
            map.put(text[0..eq], text[eq + 1 ..]) catch return null;
        }
        environ_map = map;
    }
    return &environ_map.?;
}

/// git's full path from $PATH: argv[0] is looked up in the Io's environment, not ours
var git_path: ?[]const u8 = null;

fn gitPath(arena: std.mem.Allocator, io: std.Io) []const u8 {
    if (git_path) |path| return path;
    var found: []const u8 = "git";
    var dirs = std.mem.splitScalar(u8, sys.getenv("PATH") orelse "/usr/bin:/bin", ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.allocPrint(arena, "{s}/git", .{dir}) catch continue;
        if (std.Io.Dir.cwd().access(io, candidate, .{ .execute = true })) |_| {
            found = candidate;
            break;
        } else |_| {}
    }
    git_path = found;
    return found;
}

fn writeOut(text: []const u8) void {
    var written: usize = 0;
    while (written < text.len) {
        written += sys.write(posix.STDOUT_FILENO, text[written..]) catch return;
    }
}

fn oom() ?Made {
    return fail("out of memory", .{});
}

fn fail(comptime fmt: []const u8, args: anytype) ?Made {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "clauntty: " ++ fmt ++ "\n", args) catch "clauntty: error\n";
    if (!builtin.is_test) _ = sys.write(posix.STDERR_FILENO, msg) catch {};
    return null;
}

const testing = std.testing;

test "lockfile and minified" {
    try testing.expect(lockfile("web/package-lock.json"));
    try testing.expect(lockfile("Package.resolved"));
    try testing.expect(!lockfile("src/lock.zig"));
    try testing.expect(minified("dist/app.min.js"));
    try testing.expect(!minified("src/app.js"));
}

test "lineCount" {
    try testing.expectEqual(@as(u32, 0), lineCount(""));
    try testing.expectEqual(@as(u32, 1), lineCount("a"));
    try testing.expectEqual(@as(u32, 2), lineCount("a\nb\n"));
    try testing.expectEqual(@as(u32, 2), lineCount("a\nb"));
}
