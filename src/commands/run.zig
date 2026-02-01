//! Run command - Single prompt execution (non-interactive)
//!
//! This command takes a prompt and runs it once, outputting the response and exiting.
//!
//! Usage:
//!   chatllm run -m <model.bin> -p "Your prompt here" [options]
//!
//! Examples:
//!   chatllm run -m model.bin -p "What is 2+2?"
//!   chatllm run -m model.bin -p "Translate to French: Hello" -q
//!   chatllm run -m model.bin -p "Summarize this" --json

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;
const ArrayListManaged = std.array_list.AlignedManaged;

/// Run command configuration
const RunConfig = struct {
    model_path: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    threads: ?[]const u8 = null,
    temp: ?[]const u8 = null,
    top_p: ?[]const u8 = null,
    top_k: ?[]const u8 = null,
    repeat_penalty: ?[]const u8 = null,
    max_tokens: ?[]const u8 = null,
    quiet: bool = false,
    json_output: bool = false,
    show_help: bool = false,
};

/// Application state for capturing the response
const RunState = struct {
    allocator: Allocator,
    response_buffer: ArrayListManaged(u8, null),
    token_count: usize = 0,
    start_time: i64 = 0,
    quiet: bool = false,
    json_output: bool = false,
    has_error: bool = false,
    error_message: ArrayListManaged(u8, null),

    fn init(allocator: Allocator, quiet: bool, json_output: bool) RunState {
        return .{
            .allocator = allocator,
            .response_buffer = ArrayListManaged(u8, null).init(allocator),
            .quiet = quiet,
            .json_output = json_output,
            .error_message = ArrayListManaged(u8, null).init(allocator),
        };
    }

    fn deinit(self: *RunState) void {
        self.response_buffer.deinit();
        self.error_message.deinit();
    }

    fn clearBuffer(self: *RunState) void {
        self.response_buffer.clearRetainingCapacity();
        self.token_count = 0;
    }
};

/// Callback context for bridging to C API
const CallbackCtx = chatllm.CallbackContext(*RunState);

/// Print callback - receives streamed output from the model
fn printCallback(state: *RunState, print_type: chatllm.PrintType, text: []const u8) void {
    switch (print_type) {
        .chat_chunk => {
            // Stream chat output directly if not in quiet/json mode
            if (!state.quiet and !state.json_output) {
                std.debug.print("{s}", .{text});
            }
            state.response_buffer.appendSlice(text) catch {};
            // Count tokens approximately (each callback is roughly one token)
            state.token_count += 1;
        },
        .thought_chunk => {
            // Include thought in response but don't stream if quiet
            if (!state.quiet and !state.json_output) {
                std.debug.print("{s}", .{text});
            }
        },
        .@"error" => {
            state.has_error = true;
            state.error_message.appendSlice(text) catch {};
            if (!state.json_output) {
                std.debug.print("[error] {s}\n", .{text});
            }
        },
        else => {
            // Ignore other output types in run mode
        },
    }
}

/// End callback - called when generation completes
fn endCallback(state: *RunState) void {
    if (!state.quiet and !state.json_output) {
        std.debug.print("\n", .{});
    }
}

/// Print usage information
fn printUsage() void {
    std.debug.print(
        \\chatllm run - Single prompt execution (non-interactive)
        \\
        \\Usage: chatllm run [options]
        \\
        \\Required:
        \\  -m, --model <path>       Path to the model file
        \\  -p, --prompt <text>      The prompt to run
        \\
        \\Options:
        \\  -s, --system <prompt>    System prompt
        \\  -t, --threads <n>        Number of threads to use
        \\  --temp <f>               Temperature (default: 0.7)
        \\  --top-p <f>              Top-p sampling (default: 0.9)
        \\  --top-k <n>              Top-k sampling (default: 40)
        \\  --repeat-penalty <f>     Repeat penalty (default: 1.1)
        \\  --max-tokens <n>         Maximum tokens to generate (-1 for unlimited)
        \\  -q, --quiet              Only output the response, no decorations
        \\  --json                   Output as JSON with response field
        \\  -h, --help               Show this help message
        \\
        \\Examples:
        \\  chatllm run -m model.bin -p "What is 2+2?"
        \\  chatllm run -m model.bin -p "Translate to French: Hello" -q
        \\  chatllm run -m model.bin -p "Summarize this" --json
        \\
        \\JSON output format:
        \\  {{"response": "The answer is 4.", "tokens": 10, "time_ms": 150}}
        \\
    , .{});
}

/// Parse run command arguments
fn parseArgs(args: []const []const u8) RunConfig {
    var config = RunConfig{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.show_help = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json_output = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                config.model_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt")) {
            i += 1;
            if (i < args.len) {
                config.prompt = args[i];
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
                config.temp = args[i];
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

/// Build chatllm parameters from config
fn buildParams(allocator: Allocator, config: *const RunConfig) !ArrayListManaged([]const u8, null) {
    var params = ArrayListManaged([]const u8, null).init(allocator);
    errdefer params.deinit();

    // Model path (required)
    if (config.model_path) |path| {
        try params.append("-m");
        try params.append(path);
    }

    // System prompt
    if (config.system_prompt) |prompt| {
        try params.append("-s");
        try params.append(prompt);
    }

    // Threads
    if (config.threads) |threads| {
        try params.append("-t");
        try params.append(threads);
    }

    // Temperature
    if (config.temp) |temp| {
        try params.append("--temp");
        try params.append(temp);
    }

    // Top-p
    if (config.top_p) |top_p| {
        try params.append("--top_p");
        try params.append(top_p);
    }

    // Top-k
    if (config.top_k) |top_k| {
        try params.append("--top_k");
        try params.append(top_k);
    }

    // Repeat penalty
    if (config.repeat_penalty) |penalty| {
        try params.append("--repeat_penalty");
        try params.append(penalty);
    }

    // Max tokens
    if (config.max_tokens) |max| {
        try params.append("--max_tokens");
        try params.append(max);
    }

    return params;
}

/// Output JSON response
fn outputJson(state: *const RunState, time_ms: i64) void {
    // Build escaped JSON response manually
    std.debug.print("{{\"response\": \"", .{});

    for (state.response_buffer.items) |c| {
        switch (c) {
            '"' => std.debug.print("\\\"", .{}),
            '\\' => std.debug.print("\\\\", .{}),
            '\n' => std.debug.print("\\n", .{}),
            '\r' => std.debug.print("\\r", .{}),
            '\t' => std.debug.print("\\t", .{}),
            else => {
                if (c < 0x20) {
                    std.debug.print("\\u{x:0>4}", .{c});
                } else {
                    std.debug.print("{c}", .{c});
                }
            },
        }
    }

    std.debug.print("\", \"tokens\": {d}, \"time_ms\": {d}}}\n", .{
        state.token_count,
        time_ms,
    });
}

/// Main run function - exported for use by the CLI
pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // Parse arguments
    const config = parseArgs(args);

    // Show help if requested
    if (config.show_help) {
        printUsage();
        return;
    }

    // Validate required arguments
    if (config.model_path == null) {
        std.debug.print("Error: Model path is required. Use -m <path> to specify.\n\n", .{});
        printUsage();
        return error.MissingArgument;
    }

    if (config.prompt == null) {
        std.debug.print("Error: Prompt is required. Use -p <text> to specify.\n\n", .{});
        printUsage();
        return error.MissingArgument;
    }

    // Initialize state
    var state = RunState.init(allocator, config.quiet, config.json_output);
    defer state.deinit();

    // Build parameters
    var params = try buildParams(allocator, &config);
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
    if (!config.quiet and !config.json_output) {
        std.debug.print("Loading model...\n", .{});
    }

    llm.startWithContext(*RunState, &callback_ctx) catch |err| {
        if (config.json_output) {
            std.debug.print("{{\"error\": \"Failed to start model: {}\"}}\n", .{err});
        } else {
            std.debug.print("Failed to start model: {}\n", .{err});
        }
        return err;
    };

    // Record start time
    state.start_time = std.time.milliTimestamp();

    // Clear state for response
    state.clearBuffer();

    // Send prompt to model (synchronous - blocks until complete)
    llm.userInput(config.prompt.?) catch |err| {
        if (config.json_output) {
            std.debug.print("{{\"error\": \"Failed to process prompt: {}\"}}\n", .{err});
        } else {
            std.debug.print("Failed to process prompt: {}\n", .{err});
        }
        return err;
    };

    // Calculate elapsed time
    const end_time = std.time.milliTimestamp();
    const elapsed_ms = end_time - state.start_time;

    // Output result
    if (config.json_output) {
        outputJson(&state, elapsed_ms);
    } else if (config.quiet) {
        // In quiet mode, just output the raw response
        std.debug.print("{s}\n", .{state.response_buffer.items});
    }
    // Non-quiet, non-json mode already streamed output via callback
}

/// Error types for the run command
pub const RunError = error{
    MissingArgument,
    InitFailed,
} || chatllm.Error || Allocator.Error;

// =============================================================================
// Tests
// =============================================================================

test "parseArgs basic" {
    const testing = std.testing;

    const args = [_][]const u8{ "-m", "model.bin", "-p", "Hello world" };
    const config = parseArgs(&args);

    try testing.expectEqualStrings("model.bin", config.model_path.?);
    try testing.expectEqualStrings("Hello world", config.prompt.?);
    try testing.expect(!config.quiet);
    try testing.expect(!config.json_output);
}

test "parseArgs with options" {
    const testing = std.testing;

    const args = [_][]const u8{ "-m", "model.bin", "-p", "Test", "-q", "--json", "--temp", "0.5" };
    const config = parseArgs(&args);

    try testing.expectEqualStrings("model.bin", config.model_path.?);
    try testing.expectEqualStrings("Test", config.prompt.?);
    try testing.expect(config.quiet);
    try testing.expect(config.json_output);
    try testing.expectEqualStrings("0.5", config.temp.?);
}

test "parseArgs help" {
    const testing = std.testing;

    const args = [_][]const u8{"--help"};
    const config = parseArgs(&args);

    try testing.expect(config.show_help);
}
