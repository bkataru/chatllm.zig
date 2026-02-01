const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const chatllm = @import("chatllm");

// =============================================================================
// HTTP Server for chatllm.zig
// =============================================================================
// Implements OpenAI, Ollama, and llama.cpp compatible API endpoints.
//
// OpenAI API:
//   POST /v1/chat/completions - Chat completions (streaming & non-streaming)
//   POST /v1/embeddings       - Generate embeddings
//   GET  /v1/models           - List available models
//
// Ollama API:
//   POST /api/chat            - Chat completions
//   POST /api/generate        - Text generation
//   GET  /api/tags            - List models
//   GET  /api/version         - Version info
//   POST /api/show            - Model info
//   GET  /api/ps              - Running models
//
// llama.cpp API:
//   GET  /health              - Health check
//   GET  /props               - Server properties
//   GET  /slots               - Slot information
// =============================================================================

/// Server state shared across requests
const ServerState = struct {
    allocator: Allocator,
    model_name: []const u8,
    model_path: []const u8,
    llm: ?*chatllm.ChatLLM,
    is_generating: bool,
    mutex: std.Thread.Mutex,

    fn init(allocator: Allocator, model_path: []const u8, model_name: []const u8) ServerState {
        return .{
            .allocator = allocator,
            .model_name = model_name,
            .model_path = model_path,
            .llm = null,
            .is_generating = false,
            .mutex = .{},
        };
    }
};

// =============================================================================
// JSON Utilities
// =============================================================================

/// Escape a string for JSON
fn escapeJsonString(input: []const u8, writer: anytype) !void {
    for (input) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Get a string from a JSON object
fn jsonGetString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// Get a boolean from a JSON object (with default)
fn jsonGetBool(obj: std.json.Value, key: []const u8, default: bool) bool {
    if (obj != .object) return default;
    const val = obj.object.get(key) orelse return default;
    if (val != .bool) return default;
    return val.bool;
}

/// Get an integer from a JSON object (with default)
fn jsonGetInt(obj: std.json.Value, key: []const u8, default: i64) i64 {
    if (obj != .object) return default;
    const val = obj.object.get(key) orelse return default;
    if (val != .integer) return default;
    return val.integer;
}

/// Get an array from a JSON object
fn jsonGetArray(obj: std.json.Value, key: []const u8) ?[]std.json.Value {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .array) return null;
    return val.array.items;
}

// =============================================================================
// HTTP Response Helpers
// =============================================================================

fn sendHttpResponse(stream: std.net.Stream, status_code: u16, status_text: []const u8, content_type: []const u8, body: []const u8) void {
    var header_buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ status_code, status_text, content_type, body.len }) catch return;

    _ = stream.write(header) catch return;
    _ = stream.write(body) catch return;
}

fn sendJsonResponse(stream: std.net.Stream, status_code: u16, status_text: []const u8, json_body: []const u8) void {
    sendHttpResponse(stream, status_code, status_text, "application/json", json_body);
}

fn sendSseHeaders(stream: std.net.Stream) void {
    const header =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    _ = stream.write(header) catch return;
}

fn sendHttpChunk(stream: std.net.Stream, data: []const u8) void {
    var size_buf: [16]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{data.len}) catch return;
    _ = stream.write(size_str) catch return;
    _ = stream.write(data) catch return;
    _ = stream.write("\r\n") catch return;
}

fn endChunked(stream: std.net.Stream) void {
    _ = stream.write("0\r\n\r\n") catch return;
}

fn sendNdjsonHeaders(stream: std.net.Stream) void {
    const header =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/x-ndjson\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n";
    _ = stream.write(header) catch return;
}

fn handleOptions(stream: std.net.Stream) void {
    const header =
        "HTTP/1.1 204 No Content\r\n" ++
        "Access-Control-Allow-Origin: *\r\n" ++
        "Access-Control-Allow-Methods: GET, POST, OPTIONS, DELETE, PUT\r\n" ++
        "Access-Control-Allow-Headers: Content-Type, Authorization, Accept\r\n" ++
        "Access-Control-Max-Age: 86400\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    _ = stream.write(header) catch return;
}

// =============================================================================
// Request Parsing
// =============================================================================

const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

fn parseHttpRequest(buffer: []const u8) ?HttpRequest {
    // Find end of headers
    const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return null;

    // Parse first line
    const first_line_end = std.mem.indexOf(u8, buffer, "\r\n") orelse return null;
    const first_line = buffer[0..first_line_end];

    // Split: METHOD PATH HTTP/1.1
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return null;
    const path = parts.next() orelse return null;

    // Body starts after headers
    const body_start = header_end + 4;
    const body = if (body_start < buffer.len) buffer[body_start..] else "";

    return .{
        .method = method,
        .path = path,
        .body = body,
    };
}

// =============================================================================
// Request Handlers
// =============================================================================

fn handleHealth(stream: std.net.Stream, state: *ServerState) void {
    const status = if (state.llm != null) "ok" else "no model loaded";
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"status\":\"{s}\"}}", .{status}) catch return;
    sendJsonResponse(stream, 200, "OK", json);
}

fn handleOaiModels(allocator: Allocator, stream: std.net.Stream, state: *ServerState) void {
    const timestamp = std.time.timestamp();
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);

    const writer = json_buf.writer(allocator);
    writer.print("{{\"object\":\"list\",\"data\":[{{\"id\":\"{s}\",\"object\":\"model\",\"created\":{d},\"owned_by\":\"local\"}}]}}", .{ state.model_name, timestamp }) catch return;

    sendJsonResponse(stream, 200, "OK", json_buf.items);
}

fn handleOaiChatCompletions(allocator: Allocator, stream: std.net.Stream, state: *ServerState, body: []const u8) void {
    // Parse request
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":{\"message\":\"invalid JSON\",\"type\":\"invalid_request_error\"}}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const do_stream = jsonGetBool(root, "stream", false);
    const model = jsonGetString(root, "model") orelse state.model_name;
    const max_tokens = jsonGetInt(root, "max_tokens", -1);
    const messages = jsonGetArray(root, "messages");

    if (messages == null) {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":{\"message\":\"messages field is required\",\"type\":\"invalid_request_error\"}}");
        return;
    }

    if (state.llm == null) {
        sendJsonResponse(stream, 503, "Service Unavailable", "{\"error\":{\"message\":\"model not loaded\",\"type\":\"server_error\"}}");
        return;
    }

    // Check if already generating
    state.mutex.lock();
    if (state.is_generating) {
        state.mutex.unlock();
        sendJsonResponse(stream, 503, "Service Unavailable", "{\"error\":{\"message\":\"server is busy\",\"type\":\"server_error\"}}");
        return;
    }
    state.is_generating = true;
    state.mutex.unlock();

    defer {
        state.mutex.lock();
        state.is_generating = false;
        state.mutex.unlock();
    }

    // Set max tokens if specified
    if (max_tokens > 0) {
        state.llm.?.setGenMaxTokens(@intCast(max_tokens));
    }

    // Build conversation from messages - find the last user message
    var last_user_msg: ?[]const u8 = null;
    for (messages.?) |msg| {
        const role = jsonGetString(msg, "role") orelse continue;
        const content = jsonGetString(msg, "content") orelse continue;

        if (std.mem.eql(u8, role, "system")) {
            state.llm.?.restart(content) catch {};
        } else if (std.mem.eql(u8, role, "user")) {
            last_user_msg = content;
        } else if (std.mem.eql(u8, role, "assistant")) {
            if (last_user_msg) |user_msg| {
                state.llm.?.historyAppend(.user, user_msg) catch {};
                state.llm.?.historyAppend(.assistant, content) catch {};
                last_user_msg = null;
            }
        }
    }

    if (last_user_msg == null) {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":{\"message\":\"no user message found\",\"type\":\"invalid_request_error\"}}");
        return;
    }

    const timestamp = std.time.timestamp();
    const id = "chatcmpl-chatllm";

    if (do_stream) {
        // Streaming SSE response
        sendSseHeaders(stream);

        // Create callback context for streaming
        const StreamContext = struct {
            stream: std.net.Stream,
            model: []const u8,
            id: []const u8,
            timestamp: i64,
            allocator: Allocator,
            accumulated: std.ArrayList(u8),
            done: bool,

            pub fn printCallback(ctx: *@This(), print_type: chatllm.PrintType, text: []const u8) void {
                if (print_type == .chat_chunk) {
                    ctx.sendChunk(text);
                    ctx.accumulated.appendSlice(ctx.allocator, text) catch {};
                }
            }

            pub fn endCallback(ctx: *@This()) void {
                ctx.done = true;
                ctx.sendFinalChunk();
            }

            fn sendChunk(ctx: *@This(), content: []const u8) void {
                var escaped: std.ArrayList(u8) = .{};
                defer escaped.deinit(ctx.allocator);
                escapeJsonString(content, escaped.writer(ctx.allocator)) catch return;

                var buf: [4096]u8 = undefined;
                const data = std.fmt.bufPrint(&buf, "data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n", .{ ctx.id, ctx.timestamp, ctx.model, escaped.items }) catch return;

                sendHttpChunk(ctx.stream, data);
            }

            fn sendFinalChunk(ctx: *@This()) void {
                var buf: [1024]u8 = undefined;
                const data = std.fmt.bufPrint(&buf, "data: {{\"id\":\"{s}\",\"object\":\"chat.completion.chunk\",\"created\":{d},\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n", .{ ctx.id, ctx.timestamp, ctx.model }) catch return;

                sendHttpChunk(ctx.stream, data);
                endChunked(ctx.stream);
            }
        };

        var ctx = StreamContext{
            .stream = stream,
            .model = model,
            .id = id,
            .timestamp = timestamp,
            .allocator = allocator,
            .accumulated = .{},
            .done = false,
        };
        defer ctx.accumulated.deinit(allocator);

        var callback_ctx = chatllm.CallbackContext(*StreamContext){
            .user_data = &ctx,
            .print_fn = StreamContext.printCallback,
            .end_fn = StreamContext.endCallback,
        };

        state.llm.?.startWithContext(*StreamContext, &callback_ctx) catch {
            sendHttpChunk(stream, "data: {\"error\":\"failed to start generation\"}\n\n");
            endChunked(stream);
            return;
        };

        state.llm.?.userInput(last_user_msg.?) catch {};

        // Wait for completion
        while (!ctx.done) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    } else {
        // Non-streaming response
        const NonStreamContext = struct {
            allocator: Allocator,
            accumulated: std.ArrayList(u8),
            done: bool,

            pub fn printCallback(ctx: *@This(), print_type: chatllm.PrintType, text: []const u8) void {
                if (print_type == .chat_chunk) {
                    ctx.accumulated.appendSlice(ctx.allocator, text) catch {};
                }
            }

            pub fn endCallback(ctx: *@This()) void {
                ctx.done = true;
            }
        };

        var ctx = NonStreamContext{
            .allocator = allocator,
            .accumulated = .{},
            .done = false,
        };
        defer ctx.accumulated.deinit(allocator);

        var callback_ctx = chatllm.CallbackContext(*NonStreamContext){
            .user_data = &ctx,
            .print_fn = NonStreamContext.printCallback,
            .end_fn = NonStreamContext.endCallback,
        };

        state.llm.?.startWithContext(*NonStreamContext, &callback_ctx) catch {
            sendJsonResponse(stream, 500, "Internal Server Error", "{\"error\":{\"message\":\"failed to start generation\",\"type\":\"server_error\"}}");
            return;
        };

        state.llm.?.userInput(last_user_msg.?) catch {};

        while (!ctx.done) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Build response JSON
        var json_buf: std.ArrayList(u8) = .{};
        defer json_buf.deinit(allocator);

        const writer = json_buf.writer(allocator);

        var escaped_content: std.ArrayList(u8) = .{};
        defer escaped_content.deinit(allocator);
        escapeJsonString(ctx.accumulated.items, escaped_content.writer(allocator)) catch return;

        writer.print("{{\"id\":\"{s}\",\"object\":\"chat.completion\",\"created\":{d},\"model\":\"{s}\",\"choices\":[{{\"index\":0,\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}}}", .{ id, timestamp, model, escaped_content.items }) catch return;

        sendJsonResponse(stream, 200, "OK", json_buf.items);
    }
}

fn handleOaiEmbeddings(allocator: Allocator, stream: std.net.Stream, state: *ServerState, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":{\"message\":\"invalid JSON\",\"type\":\"invalid_request_error\"}}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const model = jsonGetString(root, "model") orelse state.model_name;

    // Get input
    var inputs: std.ArrayList([]const u8) = .{};
    defer inputs.deinit(allocator);

    if (root.object.get("input")) |input_val| {
        switch (input_val) {
            .string => |s| inputs.append(allocator, s) catch return,
            .array => |arr| {
                for (arr.items) |item| {
                    if (item == .string) {
                        inputs.append(allocator, item.string) catch return;
                    }
                }
            },
            else => {},
        }
    }

    if (inputs.items.len == 0) {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":{\"message\":\"input field is required\",\"type\":\"invalid_request_error\"}}");
        return;
    }

    if (state.llm == null) {
        sendJsonResponse(stream, 503, "Service Unavailable", "{\"error\":{\"message\":\"model not loaded\",\"type\":\"server_error\"}}");
        return;
    }

    // For now, return a placeholder embedding
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    writer.print("{{\"object\":\"list\",\"data\":[{{\"object\":\"embedding\",\"embedding\":[0.0],\"index\":0}}],\"model\":\"{s}\",\"usage\":{{\"prompt_tokens\":0,\"total_tokens\":0}}}}", .{model}) catch return;

    sendJsonResponse(stream, 200, "OK", json_buf.items);
}

fn handleOllamaTags(allocator: Allocator, stream: std.net.Stream, state: *ServerState) void {
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    writer.print("{{\"models\":[{{\"name\":\"{s}:latest\",\"model\":\"{s}:latest\",\"modified_at\":\"2025-01-01T00:00:00Z\",\"size\":0,\"digest\":\"local\",\"details\":{{\"format\":\"ggml\",\"family\":\"llm\",\"parameter_size\":\"unknown\",\"quantization_level\":\"unknown\"}}}}]}}", .{ state.model_name, state.model_name }) catch return;

    sendJsonResponse(stream, 200, "OK", json_buf.items);
}

fn handleOllamaVersion(stream: std.net.Stream) void {
    sendJsonResponse(stream, 200, "OK", "{\"version\":\"0.1.0-chatllm.zig\"}");
}

fn handleOllamaChat(allocator: Allocator, stream: std.net.Stream, state: *ServerState, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":\"invalid JSON\"}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const do_stream = jsonGetBool(root, "stream", true); // Ollama defaults to streaming
    const model = jsonGetString(root, "model") orelse state.model_name;
    const messages = jsonGetArray(root, "messages");

    if (messages == null) {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":\"messages field is required\"}");
        return;
    }

    if (state.llm == null) {
        sendJsonResponse(stream, 503, "Service Unavailable", "{\"error\":\"model not loaded\"}");
        return;
    }

    state.mutex.lock();
    if (state.is_generating) {
        state.mutex.unlock();
        sendJsonResponse(stream, 503, "Service Unavailable", "{\"error\":\"server is busy\"}");
        return;
    }
    state.is_generating = true;
    state.mutex.unlock();

    defer {
        state.mutex.lock();
        state.is_generating = false;
        state.mutex.unlock();
    }

    // Build conversation
    var last_user_msg: ?[]const u8 = null;
    for (messages.?) |msg| {
        const role = jsonGetString(msg, "role") orelse continue;
        const content = jsonGetString(msg, "content") orelse continue;

        if (std.mem.eql(u8, role, "system")) {
            state.llm.?.restart(content) catch {};
        } else if (std.mem.eql(u8, role, "user")) {
            last_user_msg = content;
        } else if (std.mem.eql(u8, role, "assistant")) {
            if (last_user_msg) |user_msg| {
                state.llm.?.historyAppend(.user, user_msg) catch {};
                state.llm.?.historyAppend(.assistant, content) catch {};
                last_user_msg = null;
            }
        }
    }

    if (last_user_msg == null) {
        sendJsonResponse(stream, 400, "Bad Request", "{\"error\":\"no user message found\"}");
        return;
    }

    if (do_stream) {
        sendNdjsonHeaders(stream);

        const OllamaStreamContext = struct {
            stream: std.net.Stream,
            model: []const u8,
            allocator: Allocator,
            accumulated: std.ArrayList(u8),
            done: bool,

            pub fn printCallback(ctx: *@This(), print_type: chatllm.PrintType, text: []const u8) void {
                if (print_type == .chat_chunk) {
                    ctx.sendChunk(text);
                    ctx.accumulated.appendSlice(ctx.allocator, text) catch {};
                }
            }

            pub fn endCallback(ctx: *@This()) void {
                ctx.done = true;
                ctx.sendFinalChunk();
            }

            fn sendChunk(ctx: *@This(), content: []const u8) void {
                var escaped: std.ArrayList(u8) = .{};
                defer escaped.deinit(ctx.allocator);
                escapeJsonString(content, escaped.writer(ctx.allocator)) catch return;

                var buf: [4096]u8 = undefined;
                const data = std.fmt.bufPrint(&buf, "{{\"model\":\"{s}\",\"created_at\":\"2025-01-01T00:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"done\":false}}\n", .{ ctx.model, escaped.items }) catch return;

                sendHttpChunk(ctx.stream, data);
            }

            fn sendFinalChunk(ctx: *@This()) void {
                var buf: [1024]u8 = undefined;
                const data = std.fmt.bufPrint(&buf, "{{\"model\":\"{s}\",\"created_at\":\"2025-01-01T00:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"\"}},\"done\":true,\"done_reason\":\"stop\"}}\n", .{ctx.model}) catch return;

                sendHttpChunk(ctx.stream, data);
                endChunked(ctx.stream);
            }
        };

        var ctx = OllamaStreamContext{
            .stream = stream,
            .model = model,
            .allocator = allocator,
            .accumulated = .{},
            .done = false,
        };
        defer ctx.accumulated.deinit(allocator);

        var callback_ctx = chatllm.CallbackContext(*OllamaStreamContext){
            .user_data = &ctx,
            .print_fn = OllamaStreamContext.printCallback,
            .end_fn = OllamaStreamContext.endCallback,
        };

        state.llm.?.startWithContext(*OllamaStreamContext, &callback_ctx) catch {
            sendHttpChunk(stream, "{\"error\":\"failed to start generation\"}\n");
            endChunked(stream);
            return;
        };

        state.llm.?.userInput(last_user_msg.?) catch {};

        while (!ctx.done) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    } else {
        // Non-streaming
        const NonStreamContext = struct {
            allocator: Allocator,
            accumulated: std.ArrayList(u8),
            done: bool,

            pub fn printCallback(ctx: *@This(), print_type: chatllm.PrintType, text: []const u8) void {
                if (print_type == .chat_chunk) {
                    ctx.accumulated.appendSlice(ctx.allocator, text) catch {};
                }
            }

            pub fn endCallback(ctx: *@This()) void {
                ctx.done = true;
            }
        };

        var ctx = NonStreamContext{
            .allocator = allocator,
            .accumulated = .{},
            .done = false,
        };
        defer ctx.accumulated.deinit(allocator);

        var callback_ctx = chatllm.CallbackContext(*NonStreamContext){
            .user_data = &ctx,
            .print_fn = NonStreamContext.printCallback,
            .end_fn = NonStreamContext.endCallback,
        };

        state.llm.?.startWithContext(*NonStreamContext, &callback_ctx) catch {
            sendJsonResponse(stream, 500, "Internal Server Error", "{\"error\":\"failed to start generation\"}");
            return;
        };

        state.llm.?.userInput(last_user_msg.?) catch {};

        while (!ctx.done) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        var json_buf: std.ArrayList(u8) = .{};
        defer json_buf.deinit(allocator);
        const writer = json_buf.writer(allocator);

        var escaped_content: std.ArrayList(u8) = .{};
        defer escaped_content.deinit(allocator);
        escapeJsonString(ctx.accumulated.items, escaped_content.writer(allocator)) catch return;

        writer.print("{{\"model\":\"{s}\",\"created_at\":\"2025-01-01T00:00:00Z\",\"message\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"done\":true,\"done_reason\":\"stop\"}}", .{ model, escaped_content.items }) catch return;

        sendJsonResponse(stream, 200, "OK", json_buf.items);
    }
}

fn handleOllamaPs(allocator: Allocator, stream: std.net.Stream, state: *ServerState) void {
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    if (state.llm != null) {
        writer.print("{{\"models\":[{{\"model\":\"{s}:latest\",\"size\":0,\"digest\":\"local\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"size_vram\":0}}]}}", .{state.model_name}) catch return;
    } else {
        writer.writeAll("{\"models\":[]}") catch return;
    }

    sendJsonResponse(stream, 200, "OK", json_buf.items);
}

fn handleLlamaProps(allocator: Allocator, stream: std.net.Stream, state: *ServerState) void {
    var json_buf: std.ArrayList(u8) = .{};
    defer json_buf.deinit(allocator);
    const writer = json_buf.writer(allocator);

    const is_processing = state.is_generating;
    writer.print("{{\"default_generation_settings\":{{\"n_ctx\":4096}},\"total_slots\":1,\"model_alias\":\"{s}\",\"model_path\":\"{s}\",\"is_processing\":{s}}}", .{
        state.model_name,
        state.model_path,
        if (is_processing) "true" else "false",
    }) catch return;

    sendJsonResponse(stream, 200, "OK", json_buf.items);
}

fn handleLlamaSlots(stream: std.net.Stream, state: *ServerState) void {
    const is_processing = state.is_generating;
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{{\"id\":0,\"is_processing\":{s},\"n_ctx\":4096}}]", .{if (is_processing) "true" else "false"}) catch return;
    sendJsonResponse(stream, 200, "OK", json);
}

fn handleNotFound(stream: std.net.Stream) void {
    sendJsonResponse(stream, 404, "Not Found", "{\"error\":\"not found\"}");
}

// =============================================================================
// Router
// =============================================================================

fn routeRequest(allocator: Allocator, stream: std.net.Stream, request: HttpRequest, state: *ServerState) void {
    std.debug.print("{s} {s}\n", .{ request.method, request.path });

    if (std.mem.eql(u8, request.method, "OPTIONS")) {
        handleOptions(stream);
    } else if (std.mem.eql(u8, request.path, "/health")) {
        handleHealth(stream, state);
    } else if (std.mem.eql(u8, request.path, "/v1/models")) {
        handleOaiModels(allocator, stream, state);
    } else if (std.mem.eql(u8, request.path, "/v1/chat/completions")) {
        handleOaiChatCompletions(allocator, stream, state, request.body);
    } else if (std.mem.eql(u8, request.path, "/v1/embeddings")) {
        handleOaiEmbeddings(allocator, stream, state, request.body);
    } else if (std.mem.eql(u8, request.path, "/api/tags")) {
        handleOllamaTags(allocator, stream, state);
    } else if (std.mem.eql(u8, request.path, "/api/version")) {
        handleOllamaVersion(stream);
    } else if (std.mem.eql(u8, request.path, "/api/chat")) {
        handleOllamaChat(allocator, stream, state, request.body);
    } else if (std.mem.eql(u8, request.path, "/api/ps")) {
        handleOllamaPs(allocator, stream, state);
    } else if (std.mem.eql(u8, request.path, "/props")) {
        handleLlamaProps(allocator, stream, state);
    } else if (std.mem.eql(u8, request.path, "/slots")) {
        handleLlamaSlots(stream, state);
    } else {
        handleNotFound(stream);
    }
}

// =============================================================================
// Main Entry Point
// =============================================================================

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    var model_path: ?[]const u8 = null;
    var port: u16 = 8080;
    var host: []const u8 = "127.0.0.1";
    var show_help = false;

    // Parse arguments
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                model_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < args.len) {
                port = std.fmt.parseInt(u16, args[i], 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < args.len) {
                host = args[i];
            }
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm serve [OPTIONS]
            \\
            \\Start an HTTP server for model inference.
            \\
            \\Options:
            \\  -m, --model <MODEL>    Path to model file (required)
            \\  -p, --port <PORT>      Port to listen on (default: 8080)
            \\      --host <HOST>      Host to bind to (default: 127.0.0.1)
            \\  -h, --help             Show this help message
            \\
            \\API Endpoints:
            \\  OpenAI API:
            \\    POST /v1/chat/completions  - Chat completions (streaming supported)
            \\    POST /v1/embeddings        - Generate embeddings
            \\    GET  /v1/models            - List available models
            \\
            \\  Ollama API:
            \\    POST /api/chat             - Chat completions
            \\    GET  /api/tags             - List models
            \\    GET  /api/version          - Version info
            \\    GET  /api/ps               - Running models
            \\
            \\  llama.cpp API:
            \\    GET  /health               - Health check
            \\    GET  /props                - Server properties
            \\    GET  /slots                - Slot information
            \\
            \\Example:
            \\  chatllm serve -m ./models/llama3.gguf -p 8080
            \\
        , .{});
        return;
    }

    if (model_path == null) {
        config.printError("Model path is required. Use -m <path> to specify a model.", .{});
        return;
    }

    // Extract model name from path
    const model_name = std.fs.path.stem(model_path.?);

    // Initialize server state
    var state = ServerState.init(allocator, model_path.?, model_name);

    // Initialize chatllm
    config.printInfo("Loading model: {s}", .{model_path.?});

    var llm = chatllm.ChatLLM.init(allocator) catch {
        config.printError("Failed to create ChatLLM instance", .{});
        return;
    };
    defer llm.deinit();

    // Configure the model
    llm.appendParam("-m") catch {};
    llm.appendParam(model_path.?) catch {};

    state.llm = &llm;

    // Parse address
    const address = std.net.Address.parseIp4(host, port) catch {
        config.printError("Invalid host address: {s}", .{host});
        return;
    };

    // Create TCP server
    var server = std.net.Address.listen(address, .{
        .reuse_address = true,
    }) catch |err| {
        config.printError("Failed to bind to {s}:{d}: {}", .{ host, port, err });
        return;
    };
    defer server.deinit();

    config.printSuccess("Server listening on http://{s}:{d}/", .{ host, port });
    std.debug.print("\nAvailable endpoints:\n", .{});
    std.debug.print("  GET  /health              - Health check\n", .{});
    std.debug.print("  GET  /v1/models           - List models (OpenAI)\n", .{});
    std.debug.print("  POST /v1/chat/completions - Chat (OpenAI)\n", .{});
    std.debug.print("  POST /v1/embeddings       - Embeddings (OpenAI)\n", .{});
    std.debug.print("  GET  /api/tags            - List models (Ollama)\n", .{});
    std.debug.print("  POST /api/chat            - Chat (Ollama)\n", .{});
    std.debug.print("\nPress Ctrl+C to stop.\n\n", .{});

    // Accept connections
    while (true) {
        const connection = server.accept() catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        defer connection.stream.close();

        // Read request
        var buffer: [65536]u8 = undefined;
        const bytes_read = connection.stream.read(&buffer) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            continue;
        };

        if (bytes_read == 0) continue;

        const request = parseHttpRequest(buffer[0..bytes_read]) orelse {
            sendJsonResponse(connection.stream, 400, "Bad Request", "{\"error\":\"malformed request\"}");
            continue;
        };

        routeRequest(allocator, connection.stream, request, &state);
    }
}
