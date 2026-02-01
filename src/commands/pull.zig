//! Pull Command - Download models from ModelScope or HuggingFace
//!
//! This module downloads pre-quantized models for chatllm.cpp from various sources.
//! Primary source is ModelScope (chatllm_quantized_* repositories).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");

// =============================================================================
// Model Registry
// =============================================================================

/// Model variant info
const VariantInfo = struct {
    quant: []const u8,
    size: u64,
    url: []const u8,
};

/// Model family info
const ModelInfo = struct {
    name: []const u8,
    brief: []const u8,
    default_variant: []const u8,
    variants: []const VariantEntry,
};

const VariantEntry = struct {
    name: []const u8,
    default_quant: []const u8,
    quantized: []const VariantInfo,
};

// Base URLs for model downloads
const MODELSCOPE_BASE_URL = "https://modelscope.cn/models/judd2024";
const HUGGINGFACE_BASE_URL = "https://huggingface.co";

// Popular models registry (subset from chatllm.cpp scripts/models.json)
const MODELS = [_]ModelInfo{
    .{
        .name = "llama3.1",
        .brief = "Llama 3.1 from Meta - state-of-the-art model in 8B, 70B sizes",
        .default_variant = "8b",
        .variants = &[_]VariantEntry{
            .{
                .name = "8b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q4_1", .size = 5025629376, .url = "chatllm_quantized_240726/llama3.1-8b_q4_1.bin" },
                    .{ .quant = "q8", .size = 8538752192, .url = "chatllm_quantized_240726/llama3.1-8b.bin" },
                },
            },
        },
    },
    .{
        .name = "llama3.2",
        .brief = "Llama 3.2 from Meta - small models with 1B and 3B parameters",
        .default_variant = "1b",
        .variants = &[_]VariantEntry{
            .{
                .name = "1b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 1319059600, .url = "chatllm_quantized_20250101_1/llama3.2_1b.bin" },
                },
            },
            .{
                .name = "3b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 3419876240, .url = "chatllm_quantized_20250101_1/llama3.2_3b.bin" },
                },
            },
        },
    },
    .{
        .name = "qwen3",
        .brief = "Qwen3 from Alibaba - multilingual model with thinking capabilities",
        .default_variant = "1.7b",
        .variants = &[_]VariantEntry{
            .{
                .name = "0.6b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 730000000, .url = "chatllm_quantized_qwen3/qwen3-0.6b.bin" },
                },
            },
            .{
                .name = "1.7b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 1900000000, .url = "chatllm_quantized_qwen3/qwen3-1.7b.bin" },
                },
            },
            .{
                .name = "4b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 4500000000, .url = "chatllm_quantized_qwen3/qwen3-4b.bin" },
                },
            },
        },
    },
    .{
        .name = "smollm2",
        .brief = "SmolLM2 - compact language model, 1.7B parameters",
        .default_variant = "1.7b",
        .variants = &[_]VariantEntry{
            .{
                .name = "1.7b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 1819874192, .url = "chatllm_quantized_20250101_1/smollm2-1.7b.bin" },
                },
            },
        },
    },
    .{
        .name = "mistral",
        .brief = "Mistral 7B - efficient and powerful open model",
        .default_variant = "7b",
        .variants = &[_]VariantEntry{
            .{
                .name = "7b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 7702259552, .url = "chatllm_quantized_mistral/mistral-7b-v0.3.bin" },
                },
            },
        },
    },
    .{
        .name = "gemma3",
        .brief = "Gemma 3 from Google - efficient model in multiple sizes",
        .default_variant = "1b",
        .variants = &[_]VariantEntry{
            .{
                .name = "1b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 1100000000, .url = "chatllm_quantized_gemma3/gemma3-1b.bin" },
                },
            },
        },
    },
    .{
        .name = "internlm2.5",
        .brief = "InternLM 2.5 - powerful reasoning model",
        .default_variant = "1.8b",
        .variants = &[_]VariantEntry{
            .{
                .name = "1.8b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 2008808560, .url = "chatllm_quantized_internlm2.5_1.8b/internlm2.5-1.8b.bin" },
                },
            },
            .{
                .name = "7b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 8223436400, .url = "chatllm_quantized_internlm/internlm2.5-7b.bin" },
                },
            },
        },
    },
};

// =============================================================================
// Argument Parsing
// =============================================================================

const PullArgs = struct {
    model_spec: ?[]const u8 = null,
    registry: []const u8 = "modelscope",
    list_models: bool = false,
    show_help: bool = false,
    force: bool = false,
    quiet: bool = false,
};

fn parseArgs(args: []const []const u8) PullArgs {
    var result = PullArgs{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.show_help = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            result.list_models = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            result.quiet = true;
        } else if (std.mem.eql(u8, arg, "--registry")) {
            i += 1;
            if (i < args.len) {
                result.registry = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            result.model_spec = arg;
        }
    }

    return result;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: chatllm pull [OPTIONS] <MODEL>
        \\
        \\Download a pre-quantized model for chatllm.cpp.
        \\
        \\Arguments:
        \\  <MODEL>                Model specification (e.g., llama3.1:8b:q8)
        \\
        \\Options:
        \\  -l, --list             List available models
        \\      --registry <NAME>  Model registry (default: modelscope)
        \\  -f, --force            Force re-download even if file exists
        \\  -q, --quiet            Quiet mode (minimal output)
        \\  -h, --help             Show this help message
        \\
        \\Model Specification Format:
        \\  <model_name>           Use default variant and quantization
        \\  <model_name>:<variant> Use specific variant with default quantization
        \\  <model_name>:<variant>:<quant>  Use specific variant and quantization
        \\
        \\Examples:
        \\  chatllm pull llama3.1           # Downloads llama3.1:8b:q8
        \\  chatllm pull llama3.1:8b        # Downloads llama3.1:8b with default quant
        \\  chatllm pull llama3.1:8b:q4_1   # Downloads specific quantization
        \\  chatllm pull --list             # List all available models
        \\
        \\Registries:
        \\  modelscope    ModelScope (default, better for China)
        \\  huggingface   HuggingFace Hub
        \\
    , .{});
}

fn listModels() void {
    std.debug.print("\nAvailable models:\n\n", .{});

    for (MODELS) |model| {
        std.debug.print("  {s}\n", .{model.name});
        std.debug.print("    {s}\n", .{model.brief});
        std.debug.print("    Variants: ", .{});

        for (model.variants, 0..) |variant, j| {
            if (j > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{variant.name});
            if (std.mem.eql(u8, variant.name, model.default_variant)) {
                std.debug.print(" (default)", .{});
            }
        }
        std.debug.print("\n\n", .{});
    }

    std.debug.print(
        \\Usage: chatllm pull <model_name>[:<variant>][:<quant>]
        \\
        \\Examples:
        \\  chatllm pull llama3.1
        \\  chatllm pull llama3.2:3b
        \\  chatllm pull qwen3:1.7b:q8
        \\
    , .{});
}

// =============================================================================
// Model Resolution
// =============================================================================

const ResolvedModel = struct {
    model: *const ModelInfo,
    variant: *const VariantEntry,
    quantized: *const VariantInfo,
};

fn resolveModel(spec: []const u8) ?ResolvedModel {
    // Parse spec: model_name:variant:quant
    var parts = std.mem.splitScalar(u8, spec, ':');
    const model_name = parts.next() orelse return null;
    const variant_name = parts.next();
    const quant_name = parts.next();

    // Find model
    const model = for (&MODELS) |*m| {
        if (std.mem.eql(u8, m.name, model_name)) break m;
    } else return null;

    // Find variant
    const variant_to_find = variant_name orelse model.default_variant;
    const variant = for (model.variants) |*v| {
        if (std.mem.eql(u8, v.name, variant_to_find)) break v;
    } else return null;

    // Find quantization
    const quant_to_find = quant_name orelse variant.default_quant;
    const quantized = for (variant.quantized) |*q| {
        if (std.mem.eql(u8, q.quant, quant_to_find)) break q;
    } else return null;

    return .{
        .model = model,
        .variant = variant,
        .quantized = quantized,
    };
}

// =============================================================================
// Download Implementation
// =============================================================================

fn formatSize(size: u64, buf: []u8) []const u8 {
    if (size >= 1024 * 1024 * 1024) {
        const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "? GB";
    } else if (size >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} MB", .{mb}) catch "? MB";
    } else if (size >= 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.2} KB", .{kb}) catch "? KB";
    } else {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "? B";
    }
}

fn downloadModel(allocator: Allocator, resolved: ResolvedModel, registry: []const u8, force: bool, quiet: bool) !void {
    // Build the download URL
    const url = resolved.quantized.url;

    // Parse the URL to get the repository and filename parts
    var url_parts = std.mem.splitScalar(u8, url, '/');
    const repo_name = url_parts.next() orelse return error.InvalidUrl;
    const filename = url_parts.next() orelse return error.InvalidUrl;

    // Build full URL based on registry
    var full_url_buf: [512]u8 = undefined;
    const full_url = if (std.mem.eql(u8, registry, "huggingface"))
        std.fmt.bufPrint(&full_url_buf, "{s}/{s}/resolve/main/{s}", .{ HUGGINGFACE_BASE_URL, repo_name, filename }) catch return error.UrlTooLong
    else
        std.fmt.bufPrint(&full_url_buf, "{s}/{s}/resolve/master/{s}", .{ MODELSCOPE_BASE_URL, repo_name, filename }) catch return error.UrlTooLong;

    // Get the models directory
    const models_dir = try config.getModelsDir(allocator);
    defer allocator.free(models_dir);

    // Ensure directory exists
    std.fs.cwd().makePath(models_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Build output path
    const output_path = try std.fs.path.join(allocator, &.{ models_dir, filename });
    defer allocator.free(output_path);

    // Check if file already exists
    if (!force) {
        if (std.fs.cwd().statFile(output_path)) |stat| {
            if (!quiet) {
                var size_buf: [32]u8 = undefined;
                const size_str = formatSize(stat.size, &size_buf);
                std.debug.print("Model already exists: {s} ({s})\n", .{ output_path, size_str });
                std.debug.print("Use --force to re-download.\n", .{});
            }
            return;
        } else |_| {}
    }

    if (!quiet) {
        var size_buf: [32]u8 = undefined;
        const size_str = formatSize(resolved.quantized.size, &size_buf);
        std.debug.print("\nDownloading model:\n", .{});
        std.debug.print("  Name:     {s}:{s}:{s}\n", .{ resolved.model.name, resolved.variant.name, resolved.quantized.quant });
        std.debug.print("  Size:     {s}\n", .{size_str});
        std.debug.print("  Registry: {s}\n", .{registry});
        std.debug.print("  URL:      {s}\n", .{full_url});
        std.debug.print("  Output:   {s}\n\n", .{output_path});
    }

    // Use curl or wget to download (with resume support)
    try downloadWithExternalTool(allocator, full_url, output_path, quiet);

    if (!quiet) {
        std.debug.print("\nDownload complete!\n", .{});
        std.debug.print("Model saved to: {s}\n", .{output_path});
        std.debug.print("\nTo use this model:\n", .{});
        std.debug.print("  chatllm chat -m {s}\n", .{output_path});
    }
}

fn downloadWithExternalTool(allocator: Allocator, url: []const u8, output_path: []const u8, quiet: bool) !void {
    // Try curl first, then wget
    const tools = if (builtin.os.tag == .windows)
        [_]struct { cmd: []const u8, args: []const []const u8 }{
            .{ .cmd = "curl.exe", .args = &[_][]const u8{ "-L", "-C", "-", "-o" } },
            .{ .cmd = "curl", .args = &[_][]const u8{ "-L", "-C", "-", "-o" } },
        }
    else
        [_]struct { cmd: []const u8, args: []const []const u8 }{
            .{ .cmd = "curl", .args = &[_][]const u8{ "-L", "-C", "-", "-o" } },
            .{ .cmd = "wget", .args = &[_][]const u8{ "-c", "-O" } },
        };

    for (tools) |tool| {
        // Build argv using Zig 0.15.2 ArrayList API
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(allocator);

        argv.append(allocator, tool.cmd) catch continue;
        for (tool.args) |arg| {
            argv.append(allocator, arg) catch continue;
        }
        argv.append(allocator, output_path) catch continue;
        argv.append(allocator, url) catch continue;

        if (!quiet) {
            std.debug.print("Running: {s}", .{tool.cmd});
            for (tool.args) |arg| {
                std.debug.print(" {s}", .{arg});
            }
            std.debug.print(" {s} {s}\n", .{ output_path, url });
        }

        var child = std.process.Child.init(argv.items, allocator);
        child.spawn() catch {
            // Try next tool
            continue;
        };

        const result = child.wait() catch {
            continue;
        };

        if (result.Exited == 0) {
            return; // Success
        }
    }

    // If we get here, no download tool worked
    config.printError("No download tool available. Please install curl or wget.", .{});
    std.debug.print("\nManual download:\n", .{});
    std.debug.print("  curl -L -o {s} \"{s}\"\n", .{ output_path, url });
    return error.NoDownloadTool;
}

// =============================================================================
// Main Entry Point
// =============================================================================

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    const parsed = parseArgs(args);

    if (parsed.show_help) {
        printHelp();
        return;
    }

    if (parsed.list_models) {
        listModels();
        return;
    }

    if (parsed.model_spec == null) {
        config.printError("No model specified. Use -l to list available models.", .{});
        std.debug.print("\nUsage: chatllm pull <model_name>[:<variant>][:<quant>]\n", .{});
        std.debug.print("       chatllm pull --list\n\n", .{});
        return;
    }

    // Resolve the model specification
    const resolved = resolveModel(parsed.model_spec.?) orelse {
        config.printError("Unknown model: {s}", .{parsed.model_spec.?});
        std.debug.print("\nAvailable models:\n", .{});
        for (MODELS) |model| {
            std.debug.print("  {s}\n", .{model.name});
        }
        std.debug.print("\nUse 'chatllm pull --list' for more details.\n", .{});
        return;
    };

    // Ensure config directories exist
    config.ensureConfigDirs(allocator) catch |err| {
        config.printError("Failed to create config directories: {}", .{err});
        return;
    };

    // Download the model
    downloadModel(allocator, resolved, parsed.registry, parsed.force, parsed.quiet) catch |err| {
        config.printError("Download failed: {}", .{err});
        return;
    };
}
