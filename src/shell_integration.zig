const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const ShellType = enum {
    bash,
    zsh,
    fish,
    unknown,
};

/// Embedded shell integration scripts
pub const bash_integration =
    \\# Clauntty Shell Integration for Bash (embedded in rtach)
    \\# Emits OSC 133 sequences for terminal prompt detection
    \\[[ "$-" != *i* ]] && return
    \\[[ -n "$CLAUNTTY_SHELL_INTEGRATION" ]] && return
    \\export CLAUNTTY_SHELL_INTEGRATION=1
    \\_clauntty_executing=""
    \\__clauntty_precmd() {
    \\    local ret=$?
    \\    if [[ -n "$_clauntty_executing" ]]; then
    \\        builtin printf '\e]133;D;%s\a' "$ret"
    \\    fi
    \\    builtin printf '\e]133;A\a'
    \\    _clauntty_executing=""
    \\}
    \\__clauntty_preexec() {
    \\    builtin printf '\e]133;C\a'
    \\    _clauntty_executing=1
    \\}
    \\trap '__clauntty_preexec' DEBUG
    \\PROMPT_COMMAND="__clauntty_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    \\
;

pub const zsh_integration =
    \\# Clauntty Shell Integration for Zsh (embedded in rtach)
    \\[[ -o interactive ]] || return
    \\[[ -n "$CLAUNTTY_SHELL_INTEGRATION" ]] && return
    \\export CLAUNTTY_SHELL_INTEGRATION=1
    \\typeset -g _clauntty_executing=""
    \\__clauntty_precmd() {
    \\    local ret=$?
    \\    [[ -n "$_clauntty_executing" ]] && print -n "\e]133;D;${ret}\a"
    \\    print -n "\e]133;A\a"
    \\    _clauntty_executing=""
    \\}
    \\__clauntty_preexec() {
    \\    print -n "\e]133;C\a"
    \\    _clauntty_executing=1
    \\}
    \\autoload -Uz add-zsh-hook
    \\add-zsh-hook precmd __clauntty_precmd
    \\add-zsh-hook preexec __clauntty_preexec
    \\
;

pub const fish_integration =
    \\# Clauntty Shell Integration for Fish (embedded in rtach)
    \\status is-interactive; or exit
    \\set -q CLAUNTTY_SHELL_INTEGRATION; and exit
    \\set -gx CLAUNTTY_SHELL_INTEGRATION 1
    \\set -g _clauntty_executing ""
    \\function __clauntty_prompt --on-event fish_prompt
    \\    set -l s $status
    \\    test -n "$_clauntty_executing"; and printf '\e]133;D;%s\a' $s
    \\    printf '\e]133;A\a'
    \\    set -g _clauntty_executing ""
    \\end
    \\function __clauntty_preexec --on-event fish_preexec
    \\    printf '\e]133;C\a'
    \\    set -g _clauntty_executing 1
    \\end
    \\
;

/// Detect shell type from command path
pub fn detectShellType(command: []const u8) ShellType {
    // Get basename
    const basename = blk: {
        if (std.mem.lastIndexOf(u8, command, "/")) |idx| {
            break :blk command[idx + 1 ..];
        }
        break :blk command;
    };

    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    if (std.mem.eql(u8, basename, "fish")) return .fish;

    // Check for common variations
    if (std.mem.startsWith(u8, basename, "bash")) return .bash;
    if (std.mem.startsWith(u8, basename, "zsh")) return .zsh;
    if (std.mem.startsWith(u8, basename, "fish")) return .fish;

    return .unknown;
}

/// Get the appropriate integration script for a shell type
pub fn getIntegrationScript(shell_type: ShellType) ?[]const u8 {
    return switch (shell_type) {
        .bash => bash_integration,
        .zsh => zsh_integration,
        .fish => fish_integration,
        .unknown => null,
    };
}

/// Write shell integration files to ~/.clauntty/shell-integration/
/// Returns true if successful
pub fn deployIntegrationFiles() !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Create directory
    var path_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/.clauntty/shell-integration", .{home});

    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write each integration file
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "clauntty.bash", .content = bash_integration },
        .{ .name = "clauntty.zsh", .content = zsh_integration },
        .{ .name = "clauntty.fish", .content = fish_integration },
    };

    for (files) |file| {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ dir_path, file.name });

        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll(file.content);
    }

    // Also write wrapper rcfiles that source user config + our integration

    // Bash wrapper
    {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/bashrc", .{dir_path});
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();

        var content_buf: [1024]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf,
            \\# Clauntty bashrc wrapper - sources user config then integration
            \\[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
            \\[ -f ~/.bashrc ] && . ~/.bashrc
            \\. {s}/.clauntty/shell-integration/clauntty.bash
            \\
        , .{home});
        try f.writeAll(content);
    }

    // Zsh wrapper (zshrc in ZDOTDIR)
    {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/.zshrc", .{dir_path});
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();

        var content_buf: [1024]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf,
            \\# Clauntty zshrc wrapper - sources user config then integration
            \\[ -f /etc/zsh/zshrc ] && . /etc/zsh/zshrc
            \\[ -f ~/.zshrc ] && . ~/.zshrc
            \\. {s}/.clauntty/shell-integration/clauntty.zsh
            \\
        , .{home});
        try f.writeAll(content);
    }

    log.info("deployed shell integration files to {s}", .{dir_path});
}

/// Build argv for shell with integration
/// For bash: use --rcfile to load our wrapper
/// For zsh: use ZDOTDIR environment
/// For fish: use --init-command
/// Returns the modified command and any extra environment needed
pub const ShellSetup = struct {
    /// Modified argv (null-terminated)
    argv: [8:null]?[*:0]const u8,
    argc: usize,
    /// Extra environment variable to set (e.g., ZDOTDIR=...)
    env_name: ?[*:0]const u8 = null,
    env_value: ?[*:0]const u8 = null,
};

/// Prepare shell arguments with integration
/// Caller must ensure shell_path is null-terminated
pub fn prepareShellArgs(
    allocator: std.mem.Allocator,
    shell_path: [*:0]const u8,
    shell_type: ShellType,
) !ShellSetup {
    _ = allocator; // Not needed for now since we use static buffers

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    var setup = ShellSetup{
        .argv = .{ null, null, null, null, null, null, null, null },
        .argc = 0,
    };

    // Static buffers for paths (persists for exec)
    const S = struct {
        var rcfile_path: [512:0]u8 = undefined;
        var zdotdir_name: [8:0]u8 = undefined;
        var zdotdir_value: [512:0]u8 = undefined;
        var init_cmd: [1024:0]u8 = undefined;
        var rcfile_arg: [10:0]u8 = undefined;
        var init_cmd_arg: [16:0]u8 = undefined;
    };

    switch (shell_type) {
        .bash => {
            // bash --rcfile ~/.clauntty/shell-integration/bashrc
            const path = std.fmt.bufPrintZ(&S.rcfile_path, "{s}/.clauntty/shell-integration/bashrc", .{home}) catch return error.PathTooLong;
            _ = std.fmt.bufPrintZ(&S.rcfile_arg, "--rcfile", .{}) catch unreachable;

            setup.argv[0] = shell_path;
            setup.argv[1] = &S.rcfile_arg;
            setup.argv[2] = path.ptr;
            setup.argc = 3;
        },
        .zsh => {
            // For zsh, set ZDOTDIR to our integration directory
            _ = std.fmt.bufPrintZ(&S.zdotdir_name, "ZDOTDIR", .{}) catch unreachable;
            const zdotdir = std.fmt.bufPrintZ(&S.zdotdir_value, "{s}/.clauntty/shell-integration", .{home}) catch return error.PathTooLong;

            setup.argv[0] = shell_path;
            setup.argc = 1;
            setup.env_name = &S.zdotdir_name;
            setup.env_value = zdotdir.ptr;
        },
        .fish => {
            // fish --init-command "source ~/.clauntty/shell-integration/clauntty.fish"
            const cmd = std.fmt.bufPrintZ(&S.init_cmd, "source {s}/.clauntty/shell-integration/clauntty.fish", .{home}) catch return error.PathTooLong;
            _ = std.fmt.bufPrintZ(&S.init_cmd_arg, "--init-command", .{}) catch unreachable;

            setup.argv[0] = shell_path;
            setup.argv[1] = &S.init_cmd_arg;
            setup.argv[2] = cmd.ptr;
            setup.argc = 3;
        },
        .unknown => {
            // Unknown shell - just run it directly
            setup.argv[0] = shell_path;
            setup.argc = 1;
        },
    }

    return setup;
}
