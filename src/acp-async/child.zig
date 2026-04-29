//! Subprocess agent spawn.
//!
//! Forks a child process whose stdin / stdout speak the protocol,
//! wraps the pipes in a `FileTransport`, and surfaces lifecycle
//! (wait, kill) to the caller. Stderr is left attached to the parent
//! for diagnostics.

const std = @import("std");
const acp = @import("acp");
const FileTransport = @import("file_transport.zig").FileTransport;

const log = std.log.scoped(.acp_child);

pub const SpawnOptions = struct {
    /// Command to exec. argv[0] is the program path.
    argv: []const []const u8,
    /// Working directory for the child. Defaults to the parent's cwd.
    cwd: ?std.process.Child.Cwd = null,
    /// Environment for the child. Defaults to inheriting the parent's.
    environ: ?std.process.Environ = null,
};

pub const Child = struct {
    io: std.Io,
    process: std.process.Child,
    transport: FileTransport,

    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, opts: SpawnOptions) !Child {
        const stdio: std.process.SpawnOptions.StdIo = .pipe;
        const inherit_stdio: std.process.SpawnOptions.StdIo = .inherit;

        const spawn_opts: std.process.SpawnOptions = .{
            .argv = opts.argv,
            .cwd = opts.cwd orelse .inherit,
            .environ = opts.environ orelse .inherit,
            .stdin = stdio,
            .stdout = stdio,
            .stderr = inherit_stdio,
        };

        var process = try std.process.spawn(io, spawn_opts);
        errdefer process.kill(io);

        const stdin = process.stdin orelse return error.NoStdin;
        const stdout = process.stdout orelse return error.NoStdout;

        return .{
            .io = io,
            .process = process,
            .transport = FileTransport.init(allocator, io, stdout, stdin, false),
        };
    }

    /// Wait for the child to exit, returning its term result.
    pub fn wait(self: *Child) !std.process.Child.Term {
        return self.process.wait(self.io);
    }

    /// Force-kill the child. Idempotent.
    pub fn kill(self: *Child) void {
        self.process.kill(self.io);
    }

    pub fn deinit(self: *Child) void {
        self.transport.deinit();
    }
};

// A real-IO smoke test would spawn /bin/cat and round-trip a frame, but
// std.Io in 0.16 reaches the binary via std.process.Init only — the
// test harness has no equivalent. Coverage is via cookbook + yopo
// binaries that get an Io in main.
