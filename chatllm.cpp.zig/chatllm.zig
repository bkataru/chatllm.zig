//! Idiomatic Zig wrapper for chatllm.cpp's C API
//!
//! This module provides a safe, ergonomic Zig interface to the chatllm.cpp library,
//! wrapping the underlying C API with proper memory management and Zig idioms.

const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// C API Bindings
// =============================================================================

/// Opaque handle to the C chatllm object
pub const ChatLLMObj = opaque {};

/// Print callback type for receiving output from the model
pub const PrintCallback = *const fn (user_data: ?*anyopaque, print_type: c_int, utf8_str: [*:0]const u8) callconv(.c) void;

/// End callback type for notification when generation completes
pub const EndCallback = *const fn (user_data: ?*anyopaque) callconv(.c) void;

// External C function declarations
extern "c" fn chatllm_append_init_param(utf8_str: [*:0]const u8) void;
extern "c" fn chatllm_init() c_int;
extern "c" fn chatllm_create() ?*ChatLLMObj;
extern "c" fn chatllm_destroy(obj: *ChatLLMObj) c_int;
extern "c" fn chatllm_append_param(obj: *ChatLLMObj, utf8_str: [*:0]const u8) void;
extern "c" fn chatllm_start(obj: *ChatLLMObj, f_print: PrintCallback, f_end: EndCallback, user_data: ?*anyopaque) c_int;
extern "c" fn chatllm_set_gen_max_tokens(obj: *ChatLLMObj, gen_max_tokens: c_int) void;
extern "c" fn chatllm_restart(obj: *ChatLLMObj, utf8_sys_prompt: ?[*:0]const u8) void;
extern "c" fn chatllm_multimedia_msg_prepare(obj: *ChatLLMObj) void;
extern "c" fn chatllm_multimedia_msg_append(obj: *ChatLLMObj, msg_type: [*:0]const u8, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_history_append(obj: *ChatLLMObj, role_type: c_int, utf8_str: [*:0]const u8) void;
extern "c" fn chatllm_history_append_multimedia_msg(obj: *ChatLLMObj, role_type: c_int) c_int;
extern "c" fn chatllm_get_cursor(obj: *ChatLLMObj) c_int;
extern "c" fn chatllm_set_cursor(obj: *ChatLLMObj, pos: c_int) c_int;
extern "c" fn chatllm_user_input(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_user_input_multimedia_msg(obj: *ChatLLMObj) c_int;
extern "c" fn chatllm_set_ai_prefix(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_ai_continue(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_tool_input(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_tool_completion(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_text_tokenize(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_embedding(obj: *ChatLLMObj, utf8_str: [*:0]const u8, purpose: c_int) c_int;
extern "c" fn chatllm_qa_rank(obj: *ChatLLMObj, utf8_str_q: [*:0]const u8, utf8_str_a: [*:0]const u8) c_int;
extern "c" fn chatllm_rag_select_store(obj: *ChatLLMObj, name: [*:0]const u8) c_int;
extern "c" fn chatllm_abort_generation(obj: *ChatLLMObj) void;
extern "c" fn chatllm_show_statistics(obj: *ChatLLMObj) void;
extern "c" fn chatllm_save_session(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_load_session(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_get_async_result_int(obj: *ChatLLMObj) c_int;
extern "c" fn chatllm_async_start(obj: *ChatLLMObj, f_print: PrintCallback, f_end: EndCallback, user_data: ?*anyopaque) c_int;
extern "c" fn chatllm_async_user_input(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_async_user_input_multimedia_msg(obj: *ChatLLMObj) c_int;
extern "c" fn chatllm_async_ai_continue(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_async_tool_input(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_async_tool_completion(obj: *ChatLLMObj, utf8_str: [*:0]const u8) c_int;
extern "c" fn chatllm_async_embedding(obj: *ChatLLMObj, utf8_str: [*:0]const u8, purpose: c_int) c_int;
extern "c" fn chatllm_async_qa_rank(obj: *ChatLLMObj, utf8_str_q: [*:0]const u8, utf8_str_a: [*:0]const u8) c_int;

// =============================================================================
// Zig Enums
// =============================================================================

/// Types of print output from the model
pub const PrintType = enum(c_int) {
    /// Streaming chat output chunk
    chat_chunk = 0,
    /// General information (whole line)
    meta = 1,
    /// Error message (whole line)
    @"error" = 2,
    /// Reference (whole line)
    ref = 3,
    /// Rewritten query (whole line)
    rewritten_query = 4,
    /// User input history (whole line)
    history_user = 5,
    /// AI output history (whole line)
    history_ai = 6,
    /// Tool calling output (whole line)
    tool_calling = 7,
    /// Embedding values as CSV (whole line)
    embedding = 8,
    /// Ranking score (whole line)
    ranking = 9,
    /// Token IDs as CSV (whole line)
    token_ids = 10,
    /// Internal logging (whole line)
    logging = 11,
    /// Beam search result with probability prefix (whole line)
    beam_search = 12,
    /// Model info in JSON format (whole line)
    model_info = 13,
    /// Thought chunk (streaming, with tags removed)
    thought_chunk = 14,
    /// Async operation completed event
    evt_async_completed = 100,
    /// Thought completed event
    evt_thought_completed = 101,

    /// Convert from raw C int value
    pub fn fromInt(value: c_int) ?PrintType {
        return std.meta.intToEnum(PrintType, value) catch null;
    }
};

/// Role types for chat history messages
pub const RoleType = enum(c_int) {
    user = 2,
    assistant = 3,
    tool = 4,
};

/// Purpose of embedding generation
pub const EmbeddingPurpose = enum(c_int) {
    /// Embedding for document indexing
    document = 0,
    /// Embedding for query/search
    query = 1,
};

// =============================================================================
// Error Types
// =============================================================================

pub const Error = error{
    /// Failed to create the ChatLLM object
    CreateFailed,
    /// Failed to start the model
    StartFailed,
    /// Failed to process user input
    InputFailed,
    /// Failed to perform embedding
    EmbeddingFailed,
    /// Failed to perform QA ranking
    RankingFailed,
    /// Failed to save session
    SaveSessionFailed,
    /// Failed to load session
    LoadSessionFailed,
    /// Failed to append multimedia message
    MultimediaAppendFailed,
    /// Failed to set AI prefix
    SetAiPrefixFailed,
    /// Failed to continue AI generation
    AiContinueFailed,
    /// Failed to process tool input
    ToolInputFailed,
    /// Failed to process tool completion
    ToolCompletionFailed,
    /// Failed to select RAG store
    RagSelectFailed,
    /// Failed to tokenize text
    TokenizeFailed,
    /// Failed to append history
    HistoryAppendFailed,
    /// Out of memory
    OutOfMemory,
    /// Async operation failed to start
    AsyncStartFailed,
};

// =============================================================================
// Callback Context
// =============================================================================

/// Context for bridging Zig callbacks to C callbacks
pub fn CallbackContext(comptime UserData: type) type {
    return struct {
        const Self = @This();

        /// Zig-style print callback
        pub const ZigPrintFn = *const fn (user_data: UserData, print_type: PrintType, text: []const u8) void;
        /// Zig-style end callback
        pub const ZigEndFn = *const fn (user_data: UserData) void;

        user_data: UserData,
        print_fn: ZigPrintFn,
        end_fn: ZigEndFn,

        /// C-compatible print callback that delegates to the Zig callback
        fn cPrintCallback(raw_user_data: ?*anyopaque, print_type: c_int, utf8_str: [*:0]const u8) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(raw_user_data));
            const zig_print_type = PrintType.fromInt(print_type) orelse return;
            const text = std.mem.span(utf8_str);
            self.print_fn(self.user_data, zig_print_type, text);
        }

        /// C-compatible end callback that delegates to the Zig callback
        fn cEndCallback(raw_user_data: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(raw_user_data));
            self.end_fn(self.user_data);
        }

        /// Get the C print callback function pointer
        pub fn getPrintCallback() PrintCallback {
            return &cPrintCallback;
        }

        /// Get the C end callback function pointer
        pub fn getEndCallback() EndCallback {
            return &cEndCallback;
        }
    };
}

// =============================================================================
// Main ChatLLM Wrapper
// =============================================================================

/// Idiomatic Zig wrapper for the ChatLLM C API
pub const ChatLLM = struct {
    const Self = @This();

    /// Raw C object handle
    handle: *ChatLLMObj,
    /// Allocator for string conversions
    allocator: Allocator,

    // -------------------------------------------------------------------------
    // Global Initialization
    // -------------------------------------------------------------------------

    /// Append a global initialization parameter (e.g., --rpc_endpoints)
    /// Must be called before `globalInit()` or any `init()` calls.
    pub fn appendInitParam(param: []const u8) void {
        const c_param = toCString(param);
        chatllm_append_init_param(c_param);
    }

    /// Initialize the library globally. Should be called once before creating any ChatLLM instances.
    /// Returns true on success.
    pub fn globalInit() bool {
        return chatllm_init() == 0;
    }

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Create a new ChatLLM instance
    pub fn init(allocator: Allocator) Error!Self {
        const handle = chatllm_create() orelse return Error.CreateFailed;
        return Self{
            .handle = handle,
            .allocator = allocator,
        };
    }

    /// Destroy the ChatLLM instance and free resources
    pub fn deinit(self: *Self) void {
        _ = chatllm_destroy(self.handle);
        self.* = undefined;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// Append a command-line style parameter (e.g., "-m", "model.bin")
    pub fn appendParam(self: *Self, param: []const u8) Error!void {
        const c_param = try self.allocator.dupeZ(u8, param);
        defer self.allocator.free(c_param);
        chatllm_append_param(self.handle, c_param);
    }

    /// Append multiple parameters at once
    pub fn appendParams(self: *Self, params: []const []const u8) Error!void {
        for (params) |param| {
            try self.appendParam(param);
        }
    }

    /// Set maximum number of tokens to generate per response (-1 for unlimited)
    pub fn setGenMaxTokens(self: *Self, max_tokens: i32) void {
        chatllm_set_gen_max_tokens(self.handle, @intCast(max_tokens));
    }

    /// Set a prefix for AI generation (used in all following rounds)
    pub fn setAiPrefix(self: *Self, prefix: []const u8) Error!void {
        const c_prefix = try self.allocator.dupeZ(u8, prefix);
        defer self.allocator.free(c_prefix);
        if (chatllm_set_ai_prefix(self.handle, c_prefix) != 0) {
            return Error.SetAiPrefixFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Model Control
    // -------------------------------------------------------------------------

    /// Start the model with raw C callbacks.
    /// For a more idiomatic interface, use `startWithContext`.
    pub fn startRaw(
        self: *Self,
        print_callback: PrintCallback,
        end_callback: EndCallback,
        user_data: ?*anyopaque,
    ) Error!void {
        if (chatllm_start(self.handle, print_callback, end_callback, user_data) != 0) {
            return Error.StartFailed;
        }
    }

    /// Start the model with a typed callback context
    pub fn startWithContext(
        self: *Self,
        comptime UserData: type,
        context: *CallbackContext(UserData),
    ) Error!void {
        return self.startRaw(
            CallbackContext(UserData).getPrintCallback(),
            CallbackContext(UserData).getEndCallback(),
            context,
        );
    }

    /// Async version of start with raw C callbacks
    pub fn asyncStartRaw(
        self: *Self,
        print_callback: PrintCallback,
        end_callback: EndCallback,
        user_data: ?*anyopaque,
    ) Error!void {
        if (chatllm_async_start(self.handle, print_callback, end_callback, user_data) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    /// Restart the conversation (discard history)
    pub fn restart(self: *Self, new_system_prompt: ?[]const u8) Error!void {
        if (new_system_prompt) |prompt| {
            const c_prompt = try self.allocator.dupeZ(u8, prompt);
            defer self.allocator.free(c_prompt);
            chatllm_restart(self.handle, c_prompt);
        } else {
            chatllm_restart(self.handle, null);
        }
    }

    /// Abort the current generation (async, returns immediately)
    pub fn abortGeneration(self: *Self) void {
        chatllm_abort_generation(self.handle);
    }

    /// Show timing statistics (output via print callback)
    pub fn showStatistics(self: *Self) void {
        chatllm_show_statistics(self.handle);
    }

    // -------------------------------------------------------------------------
    // User Input
    // -------------------------------------------------------------------------

    /// Send user input and wait for generation to complete (synchronous)
    pub fn userInput(self: *Self, input: []const u8) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_user_input(self.handle, c_input) != 0) {
            return Error.InputFailed;
        }
    }

    /// Send user input asynchronously (returns immediately)
    pub fn asyncUserInput(self: *Self, input: []const u8) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_async_user_input(self.handle, c_input) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    /// Continue AI generation with additional suffix
    pub fn aiContinue(self: *Self, suffix: []const u8) Error!void {
        const c_suffix = try self.allocator.dupeZ(u8, suffix);
        defer self.allocator.free(c_suffix);
        if (chatllm_ai_continue(self.handle, c_suffix) != 0) {
            return Error.AiContinueFailed;
        }
    }

    /// Async version of aiContinue
    pub fn asyncAiContinue(self: *Self, suffix: []const u8) Error!void {
        const c_suffix = try self.allocator.dupeZ(u8, suffix);
        defer self.allocator.free(c_suffix);
        if (chatllm_async_ai_continue(self.handle, c_suffix) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Tool Calling
    // -------------------------------------------------------------------------

    /// Provide tool result input
    pub fn toolInput(self: *Self, input: []const u8) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_tool_input(self.handle, c_input) != 0) {
            return Error.ToolInputFailed;
        }
    }

    /// Async version of toolInput
    pub fn asyncToolInput(self: *Self, input: []const u8) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_async_tool_input(self.handle, c_input) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    /// Feed external tool-generated text as part of AI's response
    pub fn toolCompletion(self: *Self, text: []const u8) Error!void {
        const c_text = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(c_text);
        if (chatllm_tool_completion(self.handle, c_text) != 0) {
            return Error.ToolCompletionFailed;
        }
    }

    /// Async version of toolCompletion
    pub fn asyncToolCompletion(self: *Self, text: []const u8) Error!void {
        const c_text = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(c_text);
        if (chatllm_async_tool_completion(self.handle, c_text) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Embeddings & Ranking
    // -------------------------------------------------------------------------

    /// Generate text embedding (result emitted via PRINTLN_EMBEDDING callback)
    pub fn embedding(self: *Self, input: []const u8, purpose: EmbeddingPurpose) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_embedding(self.handle, c_input, @intFromEnum(purpose)) != 0) {
            return Error.EmbeddingFailed;
        }
    }

    /// Async version of embedding
    pub fn asyncEmbedding(self: *Self, input: []const u8, purpose: EmbeddingPurpose) Error!void {
        const c_input = try self.allocator.dupeZ(u8, input);
        defer self.allocator.free(c_input);
        if (chatllm_async_embedding(self.handle, c_input, @intFromEnum(purpose)) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    /// Perform question-answer ranking (result emitted via PRINTLN_RANKING callback)
    pub fn qaRank(self: *Self, question: []const u8, answer: []const u8) Error!void {
        const c_question = try self.allocator.dupeZ(u8, question);
        defer self.allocator.free(c_question);
        const c_answer = try self.allocator.dupeZ(u8, answer);
        defer self.allocator.free(c_answer);
        if (chatllm_qa_rank(self.handle, c_question, c_answer) != 0) {
            return Error.RankingFailed;
        }
    }

    /// Async version of qaRank
    pub fn asyncQaRank(self: *Self, question: []const u8, answer: []const u8) Error!void {
        const c_question = try self.allocator.dupeZ(u8, question);
        defer self.allocator.free(c_question);
        const c_answer = try self.allocator.dupeZ(u8, answer);
        defer self.allocator.free(c_answer);
        if (chatllm_async_qa_rank(self.handle, c_question, c_answer) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    // -------------------------------------------------------------------------
    // RAG (Retrieval-Augmented Generation)
    // -------------------------------------------------------------------------

    /// Select a RAG vector store by name
    pub fn ragSelectStore(self: *Self, name: []const u8) Error!void {
        const c_name = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(c_name);
        if (chatllm_rag_select_store(self.handle, c_name) != 0) {
            return Error.RagSelectFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Tokenization
    // -------------------------------------------------------------------------

    /// Tokenize text (token IDs emitted via PRINTLN_TOKEN_IDS callback)
    /// Returns the number of tokens on success
    pub fn tokenize(self: *Self, text: []const u8) Error!usize {
        const c_text = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(c_text);
        const result = chatllm_text_tokenize(self.handle, c_text);
        if (result < 0) {
            return Error.TokenizeFailed;
        }
        return @intCast(result);
    }

    // -------------------------------------------------------------------------
    // Multimodal Messages
    // -------------------------------------------------------------------------

    /// Prepare a new multimedia message (clears previously added pieces)
    pub fn multimediaMsgPrepare(self: *Self) void {
        chatllm_multimedia_msg_prepare(self.handle);
    }

    /// Append a piece to the current multimedia message
    /// `msg_type` can be "text", "image", "video", "audio", etc.
    /// `content` is the text content or base64-encoded data
    pub fn multimediaMsgAppend(self: *Self, msg_type: []const u8, content: []const u8) Error!void {
        const c_type = try self.allocator.dupeZ(u8, msg_type);
        defer self.allocator.free(c_type);
        const c_content = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(c_content);
        if (chatllm_multimedia_msg_append(self.handle, c_type, c_content) != 0) {
            return Error.MultimediaAppendFailed;
        }
    }

    /// Send the current multimedia message as user input (synchronous)
    pub fn userInputMultimediaMsg(self: *Self) Error!void {
        if (chatllm_user_input_multimedia_msg(self.handle) != 0) {
            return Error.InputFailed;
        }
    }

    /// Async version of userInputMultimediaMsg
    pub fn asyncUserInputMultimediaMsg(self: *Self) Error!void {
        if (chatllm_async_user_input_multimedia_msg(self.handle) != 0) {
            return Error.AsyncStartFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Chat History
    // -------------------------------------------------------------------------

    /// Append a text message to chat history
    pub fn historyAppend(self: *Self, role: RoleType, content: []const u8) Error!void {
        const c_content = try self.allocator.dupeZ(u8, content);
        defer self.allocator.free(c_content);
        chatllm_history_append(self.handle, @intFromEnum(role), c_content);
    }

    /// Append the current multimedia message to chat history
    pub fn historyAppendMultimediaMsg(self: *Self, role: RoleType) Error!void {
        if (chatllm_history_append_multimedia_msg(self.handle, @intFromEnum(role)) < 0) {
            return Error.HistoryAppendFailed;
        }
    }

    /// Get the current cursor position (total processed/generated tokens)
    pub fn getCursor(self: *Self) i32 {
        return @intCast(chatllm_get_cursor(self.handle));
    }

    /// Set the cursor position (for rewinding)
    pub fn setCursor(self: *Self, pos: i32) i32 {
        return @intCast(chatllm_set_cursor(self.handle, @intCast(pos)));
    }

    // -------------------------------------------------------------------------
    // Session Persistence
    // -------------------------------------------------------------------------

    /// Save the current session to a file
    pub fn saveSession(self: *Self, path: []const u8) Error!void {
        const c_path = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(c_path);
        if (chatllm_save_session(self.handle, c_path) != 0) {
            return Error.SaveSessionFailed;
        }
    }

    /// Load a session from a file
    pub fn loadSession(self: *Self, path: []const u8) Error!void {
        const c_path = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(c_path);
        if (chatllm_load_session(self.handle, c_path) != 0) {
            return Error.LoadSessionFailed;
        }
    }

    // -------------------------------------------------------------------------
    // Async Utilities
    // -------------------------------------------------------------------------

    /// Get the integer result of the last async operation
    /// Returns null if async operation is still ongoing
    pub fn getAsyncResultInt(self: *Self) ?i32 {
        const result = chatllm_get_async_result_int(self.handle);
        // INT_MIN indicates async is still ongoing
        if (result == std.math.minInt(c_int)) {
            return null;
        }
        return @intCast(result);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert a Zig slice to a null-terminated C string (for short-lived uses)
/// Note: This creates a sentinel-terminated view if the input already has a sentinel,
/// otherwise behavior is undefined. For safe conversion, use allocator.dupeZ.
fn toCString(slice: []const u8) [*:0]const u8 {
    // This assumes the slice has a sentinel or we're in a context where
    // the memory after the slice is null. For safe conversions, always
    // use allocator.dupeZ in the ChatLLM methods.
    return @ptrCast(slice.ptr);
}

// =============================================================================
// Utility: Embedding Parser
// =============================================================================

/// Parse embedding values from the CSV string emitted by PRINTLN_EMBEDDING
pub fn parseEmbedding(allocator: Allocator, csv: []const u8) ![]f32 {
    const ArrayListManaged = std.array_list.AlignedManaged;
    var values = ArrayListManaged(f32, null).init(allocator);
    errdefer values.deinit();

    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) continue;
        const value = std.fmt.parseFloat(f32, trimmed) catch continue;
        try values.append(value);
    }

    return values.toOwnedSlice();
}

/// Parse a single ranking score from the PRINTLN_RANKING output
pub fn parseRanking(output: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    return std.fmt.parseFloat(f32, trimmed) catch null;
}

/// Parse token IDs from the CSV string emitted by PRINTLN_TOKEN_IDS
pub fn parseTokenIds(allocator: Allocator, csv: []const u8) ![]i32 {
    var ids = std.ArrayListUnmanaged(i32){};
    errdefer ids.deinit(allocator);

    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) continue;
        const id = std.fmt.parseInt(i32, trimmed, 10) catch continue;
        try ids.append(allocator, id);
    }

    return ids.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "PrintType enum conversion" {
    const testing = std.testing;

    try testing.expectEqual(PrintType.chat_chunk, PrintType.fromInt(0).?);
    try testing.expectEqual(PrintType.@"error", PrintType.fromInt(2).?);
    try testing.expectEqual(PrintType.evt_async_completed, PrintType.fromInt(100).?);
    try testing.expect(PrintType.fromInt(999) == null);
}

test "RoleType enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(c_int, 2), @intFromEnum(RoleType.user));
    try testing.expectEqual(@as(c_int, 3), @intFromEnum(RoleType.assistant));
    try testing.expectEqual(@as(c_int, 4), @intFromEnum(RoleType.tool));
}

test "EmbeddingPurpose enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(c_int, 0), @intFromEnum(EmbeddingPurpose.document));
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(EmbeddingPurpose.query));
}

test "parseEmbedding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try parseEmbedding(allocator, "0.1,0.2,0.3,0.4");
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 4), result.len);
    try testing.expectApproxEqAbs(@as(f32, 0.1), result[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), result[3], 0.001);
}

test "parseRanking" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f32, 0.85), parseRanking("0.85").?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), parseRanking("  0.5  \n").?, 0.001);
    try testing.expect(parseRanking("invalid") == null);
}

test "parseTokenIds" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try parseTokenIds(allocator, "1,3,5,8,13");
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expectEqual(@as(i32, 1), result[0]);
    try testing.expectEqual(@as(i32, 13), result[4]);
}
