//! chatllm.zig CLI - A subcommand-based command-line interface for chatllm.cpp
//!
//! Usage:
//!   chatllm <command> [options]
//!
//! Commands:
//!   chat       Interactive chat session (default)
//!   run        Run a single prompt
//!   serve      Start HTTP API server
//!   embedding  Generate text embeddings
//!   pull       Download models
//!   list       List available models

const std = @import("std");

/// Version string for the CLI
pub const version = "0.1.0";

/// Available command modules
const commands = struct {
    pub const chat = @import("commands/chat.zig");
    pub const run = @import("commands/run.zig");
    pub const serve = @import("commands/serve.zig");
    pub const embedding = @import("commands/embedding.zig");
    pub const pull = @import("commands/pull.zig");
    pub const list = @import("commands/list.zig");
};

/// Subcommand definition
const Subcommand = struct {
    name: []const u8,
    description: []const u8,
    run_fn: *const fn (std.mem.Allocator, []const []const u8) anyerror!void,
};

/// Available subcommands
const subcommands = [_]Subcommand{
    .{ .name = "chat", .description = "Interactive chat session (default)", .run_fn = commands.chat.run },
    .{ .name = "run", .description = "Run a single prompt", .run_fn = commands.run.run },
    .{ .name = "serve", .description = "Start HTTP API server", .run_fn = commands.serve.run },
    .{ .name = "embedding", .description = "Generate text embeddings", .run_fn = commands.embedding.run },
    .{ .name = "pull", .description = "Download models", .run_fn = commands.pull.run },
    .{ .name = "list", .description = "List available models", .run_fn = commands.list.run },
};

/// Print main help message
fn printHelp() void {
    const help_text =
        \\chatllm.zig - Zig wrapper for chatllm.cpp
        \\
        \\Usage: chatllm <command> [options]
        \\
        \\Commands:
        \\  chat       Interactive chat session (default)
        \\  run        Run a single prompt
        \\  serve      Start HTTP API server
        \\  embedding  Generate text embeddings
        \\  pull       Download models
        \\  list       List available models
        \\
        \\Options:
        \\  -h, --help     Show this help
        \\  -v, --version  Show version
        \\
        \\Run 'chatllm <command> --help' for command-specific help.
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

/// Print version
fn printVersion() void {
    std.debug.print("chatllm.zig version {s}\n", .{version});
}

/// Check if a string matches a known subcommand
fn findSubcommand(name: []const u8) ?Subcommand {
    for (subcommands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            return cmd;
        }
    }
    return null;
}

/// Check if argument looks like an option (starts with -)
fn isOption(arg: []const u8) bool {
    return arg.len > 0 and arg[0] == '-';
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Skip program name, get remaining args
    const user_args = if (args.len > 1) args[1..] else args[0..0];

    // No arguments: default to chat command
    if (user_args.len == 0) {
        try commands.chat.run(allocator, &.{});
        return;
    }

    const first_arg = user_args[0];

    // Check for global options
    if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, first_arg, "-v") or std.mem.eql(u8, first_arg, "--version")) {
        printVersion();
        return;
    }

    // Try to find a matching subcommand
    if (findSubcommand(first_arg)) |cmd| {
        // Pass remaining args (excluding subcommand name) to the command
        const cmd_args = if (user_args.len > 1) user_args[1..] else user_args[0..0];
        try cmd.run_fn(allocator, cmd_args);
        return;
    }

    // First arg is not a subcommand - check if it looks like an option
    if (isOption(first_arg)) {
        // Assume it's options for the default chat command
        try commands.chat.run(allocator, user_args);
        return;
    }

    // Unknown command
    std.debug.print("Error: Unknown command '{s}'\n\n", .{first_arg});
    printHelp();
    std.process.exit(1);
}
