# Development Notes

Technical notes for developing and maintaining chatllm.zig.

## Build System Overview

### Architecture

```
build.zig           # Main entry point
├── build_chatllm.zig   # chatllm.cpp C++ compilation
└── chatllm.cpp/        # Submodule (external)
    ├── src/            # Core chatllm code
    ├── models/         # Model implementations
    └── ggml/           # GGML tensor library
```

### Key Build Components

1. **build_chatllm.zig**: Compiles all C/C++ sources from chatllm.cpp
2. **build.zig**: Orchestrates the Zig CLI and library builds
3. **chatllm.cpp.zig/chatllm.zig**: Zig bindings wrapping the C API

## C++ Compilation Notes

### Compiler Flags

```zig
fn cppFlags(ctx: Context) []const []const u8 {
    return &.{
        "-std=c++20",           // C++20 for chatllm.cpp
        "-fno-sanitize=undefined", // Avoid UB sanitizer issues
        "-fexceptions",         // Exception handling required
    };
}
```

### Architecture-Specific Code

GGML has optimized paths for different architectures:

- **x86_64**: AVX/AVX2/AVX-512, AMX
- **aarch64**: NEON, SVE
- **RISC-V**: Vector extensions
- **WebAssembly**: SIMD128

The build system auto-selects based on target.

### Known Issues

1. **Windows + shared libraries**: Requires header modification for DLL exports
2. **LTO on Windows**: Disabled due to MSVC CRT compatibility issues
3. **macOS Universal Binaries**: Build separately for x86_64 and aarch64

## API Server Implementation

### HTTP Parsing

Hand-rolled HTTP/1.1 parser in `serve.zig`:

```zig
fn parseHttpRequest(buffer: []const u8) ?HttpRequest {
    // Simple but sufficient for API use
    const header_end = std.mem.indexOf(u8, buffer, "\r\n\r\n");
    // ...
}
```

### Streaming Responses

SSE (Server-Sent Events) for OpenAI compatibility:

```zig
fn sendSseHeaders(stream: std.net.Stream) void {
    const header = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream; charset=utf-8\r\n" ++
        // ...
}
```

NDJSON for Ollama compatibility:

```zig
fn sendNdjsonHeaders(stream: std.net.Stream) void {
    const header = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/x-ndjson\r\n" ++
        // ...
}
```

## Memory Management

### Allocator Usage

The CLI uses GeneralPurposeAllocator for safety:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
```

For embedded use, consider ArenaAllocator or page_allocator.

### C API String Handling

C strings must be null-terminated:

```zig
pub fn appendParam(self: *Self, param: []const u8) Error!void {
    const c_param = try self.allocator.dupeZ(u8, param);
    defer self.allocator.free(c_param);
    chatllm_append_param(self.handle, c_param);
}
```

## Testing Strategy

### Unit Tests

Run module tests:

```bash
zig build test
```

Tests cover:
- Enum conversions
- Embedding parsing
- Token ID parsing

### Integration Tests

Manual testing with actual models:

```bash
# Basic smoke test
chatllm run -m model.bin "Hello"

# API server test
chatllm serve -m model.bin &
curl http://localhost:8080/health
```

## Model Registry

### URL Format

ModelScope: `https://modelscope.cn/models/{repo}/resolve/master/{file}`
HuggingFace: `https://huggingface.co/{repo}/resolve/main/{file}`

### Adding New Models

Edit `src/commands/pull.zig`:

```zig
const MODELS = [_]ModelInfo{
    .{
        .name = "newmodel",
        .brief = "Description here",
        .default_variant = "7b",
        .variants = &[_]VariantEntry{
            .{
                .name = "7b",
                .default_quant = "q8",
                .quantized = &[_]VariantInfo{
                    .{ .quant = "q8", .size = 1234567, .url = "repo/file.bin" },
                },
            },
        },
    },
    // ...
};
```

## Cross-Compilation

### Tested Targets

```bash
# Linux from Windows/macOS
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-linux-gnu

# Windows from Linux/macOS
zig build -Dtarget=x86_64-windows

# macOS (CPU only, Metal requires native build)
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-macos
```

### Metal Backend

Metal requires native macOS build due to framework dependencies:

```zig
// Can't cross-compile Metal
if (ctx.options.backends.metal) {
    metal_lib.linkFramework("Foundation");
    metal_lib.linkFramework("Metal");
    metal_lib.linkFramework("MetalKit");
}
```

## Debugging

### Verbose Build

```bash
zig build --verbose
```

### C++ Errors

Common issues:

1. **Missing includes**: Check `addIncludePath` calls
2. **Undefined symbols**: Ensure all .cpp files are added
3. **ABI issues**: Match C++ standard across all sources

### Runtime Debugging

Enable model info output:

```zig
.model_info => {
    std.debug.print("[model] {s}\n", .{text});
},
```

## Release Checklist

1. [ ] Update version in `src/main.zig`
2. [ ] Update version in `build.zig.zon`
3. [ ] Test on Windows, macOS, Linux
4. [ ] Run `zig build test`
5. [ ] Test `chatllm pull` with fresh install
6. [ ] Create git tag
7. [ ] Push to trigger CI

## Contributing

### Code Style

- Use `zig fmt` for formatting
- Follow Zig naming conventions (snake_case)
- Add doc comments for public APIs
- Keep functions focused and small

### Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure `zig build test` passes
5. Submit PR with clear description
