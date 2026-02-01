//! Embeddings example: Generate text embeddings
//!
//! This example shows how to generate embeddings for text,
//! useful for semantic search, RAG, and similarity matching.

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;

/// Context for collecting embedding output
const EmbeddingContext = struct {
    allocator: Allocator,
    embedding_csv: std.ArrayList(u8),
    done: bool = false,

    pub fn init(allocator: Allocator) EmbeddingContext {
        return .{
            .allocator = allocator,
            .embedding_csv = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *EmbeddingContext) void {
        self.embedding_csv.deinit();
    }

    pub fn reset(self: *EmbeddingContext) void {
        self.embedding_csv.clearRetainingCapacity();
        self.done = false;
    }

    pub fn onPrint(self: *EmbeddingContext, print_type: chatllm.PrintType, text: []const u8) void {
        if (print_type == .embedding) {
            // Embedding values come as comma-separated floats
            self.embedding_csv.appendSlice(text) catch {};
        }
    }

    pub fn onEnd(self: *EmbeddingContext) void {
        self.done = true;
    }

    /// Parse the collected embedding CSV into float values
    pub fn getEmbedding(self: *EmbeddingContext) ![]f32 {
        return chatllm.parseEmbedding(self.allocator, self.embedding_csv.items);
    }
};

/// Compute cosine similarity between two embedding vectors
fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0;

    var dot_product: f32 = 0;
    var norm_a: f32 = 0;
    var norm_b: f32 = 0;

    for (a, b) |ai, bi| {
        dot_product += ai * bi;
        norm_a += ai * ai;
        norm_b += bi * bi;
    }

    const denominator = @sqrt(norm_a) * @sqrt(norm_b);
    if (denominator == 0) return 0;

    return dot_product / denominator;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize
    if (!chatllm.ChatLLM.globalInit()) {
        return error.InitFailed;
    }

    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Use an embedding model
    // Note: Make sure to use a model that supports embeddings (e.g., BGE, BCE)
    try llm.appendParam("-m");
    try llm.appendParam("path/to/embedding-model.bin");

    var ctx = EmbeddingContext.init(allocator);
    defer ctx.deinit();

    var callback = chatllm.CallbackContext(*EmbeddingContext){
        .user_data = &ctx,
        .print_fn = EmbeddingContext.onPrint,
        .end_fn = EmbeddingContext.onEnd,
    };

    std.debug.print("Loading embedding model...\n", .{});
    try llm.startWithContext(*EmbeddingContext, &callback);

    // Generate embeddings for different texts
    const texts = [_][]const u8{
        "The quick brown fox jumps over the lazy dog.",
        "A fast auburn fox leaps above the sleepy canine.",
        "Machine learning is a subset of artificial intelligence.",
        "The weather today is sunny and warm.",
    };

    var embeddings: [texts.len][]f32 = undefined;
    var valid_count: usize = 0;

    for (texts, 0..) |text, i| {
        std.debug.print("Embedding text {d}: \"{s}\"\n", .{ i + 1, text });

        ctx.reset();
        try llm.embedding(text, .document);

        embeddings[i] = try ctx.getEmbedding();
        if (embeddings[i].len > 0) {
            valid_count += 1;
            std.debug.print("  Dimension: {d}\n", .{embeddings[i].len});
            std.debug.print("  First 5 values: ", .{});
            for (embeddings[i][0..@min(5, embeddings[i].len)]) |v| {
                std.debug.print("{d:.4} ", .{v});
            }
            std.debug.print("...\n\n", .{});
        }
    }

    // Compute pairwise similarities
    if (valid_count >= 2) {
        std.debug.print("Cosine similarities:\n", .{});
        for (0..texts.len) |i| {
            for (i + 1..texts.len) |j| {
                if (embeddings[i].len > 0 and embeddings[j].len > 0) {
                    const sim = cosineSimilarity(embeddings[i], embeddings[j]);
                    std.debug.print("  Text {d} <-> Text {d}: {d:.4}\n", .{ i + 1, j + 1, sim });
                }
            }
        }
    }

    // Cleanup
    for (&embeddings) |*e| {
        if (e.len > 0) {
            allocator.free(e.*);
        }
    }

    std.debug.print("\nDone!\n", .{});
}
