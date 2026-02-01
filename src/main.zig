//! chatllm.zig CLI - A simple command-line interface for chatllm.cpp
//!
//! Usage:
//!   chatllm -m <model.bin> [options]
//!
//! This provides a basic interactive chat interface using the chatllm.cpp library.

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Writer = std.io.Writer;

// Use the managed ArrayList for convenience (it stores the allocator)
const ArrayListManaged = std.array_list.AlignedManaged;

/// ANSI color codes for terminal output
const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const magenta = "\x1b[35m";
};

/// Application state for the chat session
const AppState = struct {
    allocator: Allocator,
    response_buffer: ArrayListManaged(u8, null),
    is_generating: bool = false,
    generation_complete: bool = false,
    show_stats: bool = false,
    quiet_mode: bool = false,
    in_thought: bool = false,

    fn init(allocator: Allocator) AppState {
        return .{
            .allocator = allocator,
            .response_buffer = ArrayListManaged(u8, null).init(allocator),
        };
    }

    fn deinit(self: *AppState) void {
        self.response_buffer.deinit();
    }

    fn clearBuffer(self: *AppState) void {
        self.response_buffer.clearRetainingCapacity();
    }
};

/// Callback context for bridging to C API
const CallbackCtx = chatllm.CallbackContext(*AppState);

/// Print callback - receives streamed output from the model
fn printCallback(state: *AppState, print_type: chatllm.PrintType, text: []const u8) void {
    // Use std.debug.print for thread-safe output from callback
    switch (print_type) {
        .chat_chunk => {
            // Stream chat output directly
            if (!state.quiet_mode) {
                std.debug.print("{s}", .{text});
            }
            state.response_buffer.appendSlice(text) catch {};
        },
        .thought_chunk => {
            // Thought output (shown dimmed)
            if (!state.quiet_mode) {
                if (!state.in_thought) {
                    std.debug.print("{s}<think>{s}", .{ Color.dim, Color.reset });
                    state.in_thought = true;
                }
                std.debug.print("{s}{s}{s}", .{ Color.dim, text, Color.reset });
            }
        },
        .evt_thought_completed => {
            if (!state.quiet_mode and state.in_thought) {
                std.debug.print("{s}</think>{s}\n", .{ Color.dim, Color.reset });
                state.in_thought = false;
            }
        },
        .meta => {
            // Meta information
            if (!state.quiet_mode) {
                std.debug.print("{s}[info]{s} {s}\n", .{ Color.cyan, Color.reset, text });
            }
        },
        .@"error" => {
            // Error messages
            std.debug.print("{s}[error]{s} {s}\n", .{ Color.red, Color.reset, text });
        },
        .tool_calling => {
            // Tool calling output
            if (!state.quiet_mode) {
                std.debug.print("{s}[tool]{s} {s}\n", .{ Color.yellow, Color.reset, text });
            }
        },
        .ref => {
            // Reference output
            if (!state.quiet_mode) {
                std.debug.print("{s}[ref]{s} {s}\n", .{ Color.magenta, Color.reset, text });
            }
        },
        .model_info => {
            // Model info (JSON)
            if (!state.quiet_mode) {
                std.debug.print("{s}[model]{s} {s}\n", .{ Color.green, Color.reset, text });
            }
        },
        else => {
            // Other output types
            if (!state.quiet_mode) {
                std.debug.print("[{d}] {s}\n", .{ @intFromEnum(print_type), text });
            }
        },
    }
}

/// End callback - called when generation completes
fn endCallback(state: *AppState) void {
    state.is_generating = false;
    state.generation_complete = true;
    state.in_thought = false;

    if (!state.quiet_mode) {
        std.debug.print("\n", .{});
    }
}

/// Helper to write to stdout
fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const stdout = File.stdout().writer(&buf);
    stdout.print(fmt, args) catch {};
    stdout.flush() catch {};
}

/// Helper to write string to stdout
fn writeStdoutStr(str: []const u8) void {
    var buf: [4096]u8 = undefined;
    const stdout = File.stdout().writer(&buf);
    stdout.writeAll(str) catch {};
    stdout.flush() catch {};
}

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\chatllm.zig - Zig bindings for chatllm.cpp
        \\
        \\Usage: chatllm [options]
        \\
        \\Options:
        \\  -m, --model <path>     Path to the model file (required)
        \\  -s, --system <prompt>  System prompt
        \\  -t, --threads <n>      Number of threads to use
        \\  -c, --context <n>      Context size (default: 4096)
        \\  --temp <f>             Temperature (default: 0.7)
        \\  --top-p <f>            Top-p sampling (default: 0.9)
        \\  --top-k <n>            Top-k sampling (default: 40)
        \\  --repeat-penalty <f>   Repeat penalty (default: 1.1)
        \\  --max-tokens <n>       Maximum tokens to generate (-1 for unlimited)
        \\  -q, --quiet            Quiet mode (minimal output)
        \\  --stats                Show statistics after each response
        \\  -h, --help             Show this help message
        \\
        \\Interactive commands:
        \\  /quit, /exit           Exit the chat
        \\  /clear                 Clear conversation history
        \\  /stats                 Show generation statistics
        \\  /save <file>           Save session to file
        \\  /load <file>           Load session from file
        \\  /help                  Show available commands
        \\
    , .{});
}

/// Parse command-line arguments into chatllm parameters
fn parseArgs(allocator: Allocator, state: *AppState) !ArrayListManaged([]const u8, null) {
    var params = ArrayListManaged([]const u8, null).init(allocator);
    errdefer params.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var has_model = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            state.quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            state.show_stats = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |model_path| {
                try params.append("-m");
                try params.append(model_path);
                has_model = true;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--system")) {
            if (args.next()) |system_prompt| {
                try params.append("-s");
                try params.append(system_prompt);
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            if (args.next()) |threads| {
                try params.append("-t");
                try params.append(threads);
            }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--context")) {
            if (args.next()) |context| {
                try params.append("-c");
                try params.append(context);
            }
        } else if (std.mem.eql(u8, arg, "--temp")) {
            if (args.next()) |temp| {
                try params.append("--temp");
                try params.append(temp);
            }
        } else if (std.mem.eql(u8, arg, "--top-p")) {
            if (args.next()) |top_p| {
                try params.append("--top_p");
                try params.append(top_p);
            }
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            if (args.next()) |top_k| {
                try params.append("--top_k");
                try params.append(top_k);
            }
        } else if (std.mem.eql(u8, arg, "--repeat-penalty")) {
            if (args.next()) |penalty| {
                try params.append("--repeat_penalty");
                try params.append(penalty);
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            if (args.next()) |max| {
                try params.append("--max_tokens");
                try params.append(max);
            }
        } else {
            // Pass through unknown args directly to chatllm
            try params.append(arg);
        }
    }

    if (!has_model) {
        std.debug.print("Error: Model path is required. Use -m <path> to specify.\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    return params;
}

/// Handle interactive commands (starting with /)
fn handleCommand(llm: *chatllm.ChatLLM, input: []const u8) !bool {
    if (std.mem.eql(u8, input, "/quit") or std.mem.eql(u8, input, "/exit")) {
        return true; // Signal to exit
    } else if (std.mem.eql(u8, input, "/clear")) {
        try llm.restart(null);
        std.debug.print("Conversation cleared.\n", .{});
    } else if (std.mem.eql(u8, input, "/stats")) {
        llm.showStatistics();
    } else if (std.mem.eql(u8, input, "/help")) {
        std.debug.print(
            \\Available commands:
            \\  /quit, /exit    Exit the chat
            \\  /clear          Clear conversation history
            \\  /stats          Show generation statistics
            \\  /save <file>    Save session to file
            \\  /load <file>    Load session from file
            \\  /help           Show this help
            \\
        , .{});
    } else if (std.mem.startsWith(u8, input, "/save ")) {
        const path = std.mem.trim(u8, input[6..], " \t");
        llm.saveSession(path) catch |err| {
            std.debug.print("Failed to save session: {}\n", .{err});
            return false;
        };
        std.debug.print("Session saved to: {s}\n", .{path});
    } else if (std.mem.startsWith(u8, input, "/load ")) {
        const path = std.mem.trim(u8, input[6..], " \t");
        llm.loadSession(path) catch |err| {
            std.debug.print("Failed to load session: {}\n", .{err});
            return false;
        };
        std.debug.print("Session loaded from: {s}\n", .{path});
    } else {
        std.debug.print("Unknown command: {s}\n", .{input});
    }

    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize state
    var state = AppState.init(allocator);
    defer state.deinit();

    // Parse arguments
    var params = try parseArgs(allocator, &state);
    defer params.deinit();

    // Initialize the library
    if (!chatllm.ChatLLM.globalInit()) {
        std.debug.print("Failed to initialize chatllm library\n", .{});
        return error.InitFailed;
    }

    // Create ChatLLM instance
    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Apply parameters
    for (params.items) |param| {
        try llm.appendParam(param);
    }

    // Create callback context
    var callback_ctx = CallbackCtx{
        .user_data = &state,
        .print_fn = &printCallback,
        .end_fn = &endCallback,
    };

    // Start the model
    if (!state.quiet_mode) {
        std.debug.print("Loading model...\n", .{});
    }

    llm.startWithContext(*AppState, &callback_ctx) catch |err| {
        std.debug.print("Failed to start model: {}\n", .{err});
        return err;
    };

    if (!state.quiet_mode) {
        std.debug.print("\n", .{});
        std.debug.print("{s}chatllm.zig{s} - Interactive Chat\n", .{ Color.bold, Color.reset });
        std.debug.print("Type your message and press Enter. Use /help for commands.\n\n", .{});
    }

    // Main chat loop - use a buffered reader for stdin
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = File.stdin().reader(&stdin_buf);

    while (true) {
        // Print prompt
        std.debug.print("{s}You:{s} ", .{ Color.green, Color.reset });

        // Read input line using the new Zig 0.15 API
        const line = stdin_reader.interface.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) break;
            std.debug.print("Read error: {}\n", .{err});
            break;
        };

        const input = std.mem.trim(u8, line, " \t\r\n");

        // Skip empty input
        if (input.len == 0) continue;

        // Handle commands
        if (input[0] == '/') {
            const should_exit = try handleCommand(&llm, input);
            if (should_exit) break;
            continue;
        }

        // Print assistant prompt
        std.debug.print("{s}Assistant:{s} ", .{ Color.cyan, Color.reset });

        // Clear state for new response
        state.clearBuffer();
        state.is_generating = true;
        state.generation_complete = false;

        // Send input to model (synchronous - blocks until complete)
        llm.userInput(input) catch |err| {
            std.debug.print("\n{s}[error]{s} Failed to process input: {}\n", .{ Color.red, Color.reset, err });
            continue;
        };

        // Show stats if enabled
        if (state.show_stats) {
            llm.showStatistics();
        }
    }

    if (!state.quiet_mode) {
        std.debug.print("\nGoodbye!\n", .{});
    }
}
