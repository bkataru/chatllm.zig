//! Embedding command - Generate text embeddings using an embedding model
//!
//! This command generates embedding vectors from input text using a specified
//! embedding model. Embeddings can be used for semantic search, clustering,
//! and other vector-based operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chatllm = @import("chatllm");

// Use the managed ArrayList for convenience (it stores the allocator)
const ArrayListManaged = std.array_list.AlignedManaged;

/// State for capturing embedding output
const EmbeddingState = struct {
    embedding_data: ?[]const u8 = null,
    has_error: bool = false,
    error_msg: ?[]const u8 = null,
    completed: bool = false,
};

/// Callback context type for the embedding operation
const CallbackCtx = chatllm.CallbackContext(*EmbeddingState);

/// Print callback - captures embedding output
fn printCallback(state: *EmbeddingState, print_type: chatllm.PrintType, text: []const u8) void {
    switch (print_type) {
        .embedding => {
            state.embedding_data = text;
        },
        .@"error" => {
            state.has_error = true;
            state.error_msg = text;
        },
        else => {},
    }
}

/// End callback - signals completion
fn endCallback(state: *EmbeddingState) void {
    state.completed = true;
}

/// Command-line options for the embedding command
const Options = struct {
    model: ?[]const u8 = null,
    input: ?[]const u8 = null,
    file: ?[]const u8 = null,
    purpose: chatllm.EmbeddingPurpose = .query,
    json_output: bool = false,
    show_dim: bool = false,
    show_help: bool = false,
};

/// Parse command-line arguments
fn parseArgs(args: []const []const u8) Options {
    var opts = Options{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                opts.model = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i < args.len) {
                opts.input = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i < args.len) {
                opts.file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--purpose")) {
            i += 1;
            if (i < args.len) {
                const purpose_str = args[i];
                if (std.mem.eql(u8, purpose_str, "doc") or std.mem.eql(u8, purpose_str, "document")) {
                    opts.purpose = .document;
                } else if (std.mem.eql(u8, purpose_str, "query") or std.mem.eql(u8, purpose_str, "search")) {
                    opts.purpose = .query;
                }
            }
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--dim")) {
            opts.show_dim = true;
        }
    }

    return opts;
}

/// Print help message
fn printHelp() void {
    std.debug.print(
        \\Usage: chatllm embedding [OPTIONS]
        \\
        \\Generate embeddings from text using an embedding model.
        \\
        \\Options:
        \\  -m, --model <PATH>       Path to embedding model (required)
        \\  -i, --input <TEXT>       Text to embed (use "-" for stdin)
        \\  -f, --file <PATH>        Read input text from file
        \\      --purpose <PURPOSE>  Embedding purpose: doc|query (default: query)
        \\      --json               Output as JSON array
        \\      --dim                Print embedding dimension and exit
        \\  -h, --help               Show this help message
        \\
        \\Purpose:
        \\  doc, document    Generate embedding for document indexing
        \\  query, search    Generate embedding for search queries (default)
        \\
        \\Output formats:
        \\  Default: Space-separated floats on one line
        \\  --json:  JSON array of floats [0.123, -0.456, ...]
        \\
        \\Examples:
        \\  chatllm embedding -m embed-model.bin -i "Hello world"
        \\  chatllm embedding -m embed-model.bin -f document.txt --purpose doc
        \\  echo "text" | chatllm embedding -m embed-model.bin -i - --json
        \\  chatllm embedding -m embed-model.bin --dim
        \\
    , .{});
}

/// Read input from stdin
fn readStdin(allocator: Allocator) ![]u8 {
    const stdin = std.fs.File.stdin();

    var buffer = ArrayListManaged(u8, null).init(allocator);
    errdefer buffer.deinit();

    // Read all available input in chunks
    var chunk: [4096]u8 = undefined;
    while (true) {
        const bytes_read = stdin.read(&chunk) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (bytes_read == 0) break;
        try buffer.appendSlice(chunk[0..bytes_read]);
    }

    return buffer.toOwnedSlice();
}

/// Read input from file
fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) {
        return error.IncompleteRead;
    }

    return content;
}

/// Format embedding output as JSON array
fn formatJson(allocator: Allocator, csv: []const u8) ![]u8 {
    var output = ArrayListManaged(u8, null).init(allocator);
    errdefer output.deinit();

    try output.append('[');

    var first = true;
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (!first) {
            try output.appendSlice(", ");
        }
        first = false;

        try output.appendSlice(trimmed);
    }

    try output.append(']');

    return output.toOwnedSlice();
}

/// Format embedding output as space-separated values
fn formatSpaceSeparated(allocator: Allocator, csv: []const u8) ![]u8 {
    var output = ArrayListManaged(u8, null).init(allocator);
    errdefer output.deinit();

    var first = true;
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (!first) {
            try output.append(' ');
        }
        first = false;

        try output.appendSlice(trimmed);
    }

    return output.toOwnedSlice();
}

/// Count the number of dimensions in an embedding
fn countDimensions(csv: []const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len > 0) {
            count += 1;
        }
    }
    return count;
}

/// Main entry point for the embedding command
pub fn run(allocator: Allocator, args: []const []const u8) !void {
    // Parse arguments
    const opts = parseArgs(args);

    // Handle help
    if (opts.show_help) {
        printHelp();
        return;
    }

    // Validate required arguments
    if (opts.model == null) {
        std.debug.print("Error: Model path is required. Use -m <path> to specify.\n\n", .{});
        printHelp();
        return;
    }

    // Determine input source
    var input_text: []u8 = undefined;
    var input_owned = false;

    if (opts.file) |file_path| {
        // Read from file
        input_text = readFile(allocator, file_path) catch |err| {
            std.debug.print("Error: Failed to read file '{s}': {}\n", .{ file_path, err });
            return;
        };
        input_owned = true;
    } else if (opts.input) |input| {
        if (std.mem.eql(u8, input, "-")) {
            // Read from stdin
            input_text = readStdin(allocator) catch |err| {
                std.debug.print("Error: Failed to read from stdin: {}\n", .{err});
                return;
            };
            input_owned = true;
        } else {
            // Use provided text
            input_text = @constCast(input);
            input_owned = false;
        }
    } else if (!opts.show_dim) {
        std.debug.print("Error: Input text is required. Use -i <text> or -f <file>.\n\n", .{});
        printHelp();
        return;
    } else {
        // For --dim, we need some minimal input to generate an embedding
        input_text = @constCast("test");
        input_owned = false;
    }

    defer if (input_owned) allocator.free(input_text);

    // Trim whitespace from input
    const trimmed_input = std.mem.trim(u8, input_text, " \t\r\n");
    if (trimmed_input.len == 0 and !opts.show_dim) {
        std.debug.print("Error: Input text is empty.\n", .{});
        return;
    }

    // Initialize chatllm library
    if (!chatllm.ChatLLM.globalInit()) {
        std.debug.print("Error: Failed to initialize chatllm library.\n", .{});
        return;
    }

    // Create ChatLLM instance
    var llm = chatllm.ChatLLM.init(allocator) catch |err| {
        std.debug.print("Error: Failed to create ChatLLM instance: {}\n", .{err});
        return;
    };
    defer llm.deinit();

    // Set model parameter
    llm.appendParam("-m") catch |err| {
        std.debug.print("Error: Failed to set parameter: {}\n", .{err});
        return;
    };
    llm.appendParam(opts.model.?) catch |err| {
        std.debug.print("Error: Failed to set model path: {}\n", .{err});
        return;
    };

    // Create callback state
    var state = EmbeddingState{};

    // Create callback context
    var callback_ctx = CallbackCtx{
        .user_data = &state,
        .print_fn = &printCallback,
        .end_fn = &endCallback,
    };

    // Start the model
    llm.startWithContext(*EmbeddingState, &callback_ctx) catch |err| {
        std.debug.print("Error: Failed to load model: {}\n", .{err});
        return;
    };

    // Generate embedding
    const input_for_embedding = if (opts.show_dim) "test" else trimmed_input;
    llm.embedding(input_for_embedding, opts.purpose) catch |err| {
        std.debug.print("Error: Failed to generate embedding: {}\n", .{err});
        return;
    };

    // Check for errors
    if (state.has_error) {
        if (state.error_msg) |msg| {
            std.debug.print("Error: {s}\n", .{msg});
        } else {
            std.debug.print("Error: Unknown error during embedding generation.\n", .{});
        }
        return;
    }

    // Check if we got embedding data
    if (state.embedding_data == null) {
        std.debug.print("Error: No embedding data received. Is this an embedding model?\n", .{});
        return;
    }

    const embedding_csv = state.embedding_data.?;

    // Handle --dim flag
    if (opts.show_dim) {
        const dim = countDimensions(embedding_csv);
        std.debug.print("{d}\n", .{dim});
        return;
    }

    // Format and output the embedding
    if (opts.json_output) {
        const json_output = formatJson(allocator, embedding_csv) catch |err| {
            std.debug.print("Error: Failed to format JSON output: {}\n", .{err});
            return;
        };
        defer allocator.free(json_output);
        std.debug.print("{s}\n", .{json_output});
    } else {
        const space_output = formatSpaceSeparated(allocator, embedding_csv) catch |err| {
            std.debug.print("Error: Failed to format output: {}\n", .{err});
            return;
        };
        defer allocator.free(space_output);
        std.debug.print("{s}\n", .{space_output});
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parseArgs basic options" {
    const testing = std.testing;

    const args1 = [_][]const u8{ "-m", "model.bin", "-i", "hello" };
    const opts1 = parseArgs(&args1);
    try testing.expectEqualStrings("model.bin", opts1.model.?);
    try testing.expectEqualStrings("hello", opts1.input.?);
    try testing.expectEqual(chatllm.EmbeddingPurpose.query, opts1.purpose);
    try testing.expect(!opts1.json_output);
    try testing.expect(!opts1.show_help);
}

test "parseArgs purpose option" {
    const testing = std.testing;

    const args_doc = [_][]const u8{ "--purpose", "doc" };
    const opts_doc = parseArgs(&args_doc);
    try testing.expectEqual(chatllm.EmbeddingPurpose.document, opts_doc.purpose);

    const args_query = [_][]const u8{ "--purpose", "query" };
    const opts_query = parseArgs(&args_query);
    try testing.expectEqual(chatllm.EmbeddingPurpose.query, opts_query.purpose);
}

test "parseArgs json flag" {
    const testing = std.testing;

    const args = [_][]const u8{"--json"};
    const opts = parseArgs(&args);
    try testing.expect(opts.json_output);
}

test "formatJson" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try formatJson(allocator, "0.1,0.2,0.3");
    defer allocator.free(result);
    try testing.expectEqualStrings("[0.1, 0.2, 0.3]", result);
}

test "formatSpaceSeparated" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try formatSpaceSeparated(allocator, "0.1,0.2,0.3");
    defer allocator.free(result);
    try testing.expectEqualStrings("0.1 0.2 0.3", result);
}

test "countDimensions" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 3), countDimensions("0.1,0.2,0.3"));
    try testing.expectEqual(@as(usize, 5), countDimensions("1,2,3,4,5"));
    try testing.expectEqual(@as(usize, 0), countDimensions(""));
}
