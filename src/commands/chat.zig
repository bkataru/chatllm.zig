//! Chat Command - Interactive chat session with a language model
//!
//! This module provides an interactive chat interface that can be invoked
//! as a subcommand of the main CLI.

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;
const File = std.fs.File;

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

/// Chat command configuration parsed from arguments
const ChatConfig = struct {
    model_path: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    threads: ?[]const u8 = null,
    temperature: ?[]const u8 = null,
    top_p: ?[]const u8 = null,
    top_k: ?[]const u8 = null,
    repeat_penalty: ?[]const u8 = null,
    max_tokens: ?[]const u8 = null,
    quiet_mode: bool = false,
    show_stats: bool = false,
    show_help: bool = false,
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

/// Print chat command usage information
fn printHelp() void {
    std.debug.print(
        \\chatllm chat - Interactive chat session
        \\
        \\Usage: chatllm chat [options]
        \\
        \\Options:
        \\  -m, --model <path>       Path to the model file (required)
        \\  -s, --system <prompt>    System prompt
        \\  -t, --threads <n>        Number of threads to use
        \\  --temp <f>               Temperature (default: 0.7)
        \\  --top-p <f>              Top-p sampling (default: 0.9)
        \\  --top-k <n>              Top-k sampling (default: 40)
        \\  --repeat-penalty <f>     Repeat penalty (default: 1.1)
        \\  --max-tokens <n>         Maximum tokens to generate (-1 for unlimited)
        \\  -q, --quiet              Quiet mode (minimal output)
        \\  --stats                  Show statistics after each response
        \\  -h, --help               Show this help message
        \\
        \\Interactive commands:
        \\  /quit, /exit             Exit the chat
        \\  /clear                   Clear conversation history
        \\  /stats                   Show generation statistics
        \\  /save <file>             Save session to file
        \\  /load <file>             Load session from file
        \\  /help                    Show available commands
        \\
    , .{});
}

/// Parse chat-specific command-line arguments
fn parseArgs(args: []const []const u8) ChatConfig {
    var config = ChatConfig{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.show_help = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            config.quiet_mode = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            config.show_stats = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                config.model_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--system")) {
            i += 1;
            if (i < args.len) {
                config.system_prompt = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i < args.len) {
                config.threads = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--temp")) {
            i += 1;
            if (i < args.len) {
                config.temperature = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--top-p")) {
            i += 1;
            if (i < args.len) {
                config.top_p = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--top-k")) {
            i += 1;
            if (i < args.len) {
                config.top_k = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--repeat-penalty")) {
            i += 1;
            if (i < args.len) {
                config.repeat_penalty = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            i += 1;
            if (i < args.len) {
                config.max_tokens = args[i];
            }
        }
    }

    return config;
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

/// Main entry point for the chat command
pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // Parse chat-specific arguments
    const config = parseArgs(args);

    // Handle help flag
    if (config.show_help) {
        printHelp();
        return;
    }

    // Validate required arguments
    if (config.model_path == null) {
        std.debug.print("Error: Model path is required. Use -m <path> to specify.\n\n", .{});
        printHelp();
        return error.MissingModelPath;
    }

    // Initialize state
    var state = AppState.init(allocator);
    defer state.deinit();
    state.quiet_mode = config.quiet_mode;
    state.show_stats = config.show_stats;

    // Initialize the library
    if (!chatllm.ChatLLM.globalInit()) {
        std.debug.print("Failed to initialize chatllm library\n", .{});
        return error.InitFailed;
    }

    // Create ChatLLM instance
    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Apply parameters from config
    try llm.appendParam("-m");
    try llm.appendParam(config.model_path.?);

    if (config.system_prompt) |prompt| {
        try llm.appendParam("-s");
        try llm.appendParam(prompt);
    }

    if (config.threads) |threads| {
        try llm.appendParam("-t");
        try llm.appendParam(threads);
    }

    if (config.temperature) |temp| {
        try llm.appendParam("--temp");
        try llm.appendParam(temp);
    }

    if (config.top_p) |top_p| {
        try llm.appendParam("--top_p");
        try llm.appendParam(top_p);
    }

    if (config.top_k) |top_k| {
        try llm.appendParam("--top_k");
        try llm.appendParam(top_k);
    }

    if (config.repeat_penalty) |penalty| {
        try llm.appendParam("--repeat_penalty");
        try llm.appendParam(penalty);
    }

    if (config.max_tokens) |max| {
        try llm.appendParam("--max_tokens");
        try llm.appendParam(max);
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
