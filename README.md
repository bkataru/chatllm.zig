# chatllm.zig

[![Zig](https://img.shields.io/badge/Zig-0.15.x-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/bkataru/chatllm.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/bkataru/chatllm.zig/actions)

Zig wrapper for [chatllm.cpp](https://github.com/jzxxx/chatllm.cpp) — run ChatGLM, Qwen, Llama, DeepSeek, and 70+ other LLMs locally.

## Features

- 🚀 **Pure Zig build system** — no CMake, no Make, just `zig build`
- 📦 **CLI + Library** — use as a standalone tool or embed in your Zig project
- 🌐 **API server** — OpenAI, Ollama, and llama.cpp compatible endpoints
- 💬 **Interactive chat** — REPL with session management
- 📥 **Model registry** — download pre-quantized models with `chatllm pull`
- ⚡ **Streaming** — real-time token streaming with callbacks
- 🧮 **Embeddings** — generate text embeddings for RAG applications
- 🔧 **GPU backends** — CUDA, Vulkan, Metal support (via build options)
- 📱 **Cross-platform** — Windows, macOS, Linux, FreeBSD

## Supported Models

chatllm.zig supports all models from chatllm.cpp, including:

| Family | Models |
|--------|--------|
| **Llama** | Llama 3.x, Llama 2, Code Llama |
| **Qwen** | Qwen 3, Qwen 2.5, Qwen VL, Qwen Audio |
| **ChatGLM** | ChatGLM 4, GLM-4, CharacterGLM |
| **DeepSeek** | DeepSeek V3, DeepSeek Coder |
| **Google** | Gemma 3, Gemma 2 |
| **Mistral** | Mistral 7B, Mixtral |
| **Microsoft** | Phi-4, Phi-3 |
| **Others** | InternLM, Yi, Falcon, Baichuan, ERNIE, and 60+ more |

See the [chatllm.cpp model list](https://github.com/jzxxx/chatllm.cpp#supported-models) for the complete list.

## Installation

### CLI Tool

```bash
# Clone with submodule
git clone --recursive https://github.com/bkataru/chatllm.zig.git
cd chatllm.zig

# Build
zig build -Doptimize=ReleaseFast

# The CLI is at zig-out/bin/chatllm
./zig-out/bin/chatllm --help
```

### As a Zig Library

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .chatllm = .{
        .url = "https://github.com/bkataru/chatllm.zig/archive/refs/heads/main.tar.gz",
        // Add hash after first build attempt
    },
},
```

In your `build.zig`:

```zig
const chatllm_dep = b.dependency("chatllm", .{
    .target = target,
    .optimize = optimize,
});

// Add the module
exe.root_module.addImport("chatllm", chatllm_dep.module("chatllm"));

// Link the library
exe.linkLibrary(chatllm_dep.artifact("chatllm"));
```

## Quick Start

### Download a Model

```bash
# List available models
chatllm pull --list

# Download Qwen3 1.7B (default)
chatllm pull qwen3

# Download specific variant and quantization
chatllm pull llama3.2:3b
chatllm pull llama3.1:8b:q4_1
```

### Interactive Chat

```bash
chatllm chat -m ~/.chatllm/models/qwen3-1.7b.bin

# With system prompt
chatllm chat -m model.bin -s "You are a helpful coding assistant"
```

### Single Prompt

```bash
chatllm run -m model.bin "Explain quantum computing in simple terms"
```

### Start API Server

```bash
chatllm serve -m model.bin -p 8080

# Use with curl
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "local", "messages": [{"role": "user", "content": "Hello!"}]}'
```

### Generate Embeddings

```bash
chatllm embedding -m embedding-model.bin "Text to embed"
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `chat` | Interactive chat session (default) |
| `run` | Run a single prompt |
| `serve` | Start HTTP API server |
| `embedding` | Generate text embeddings |
| `pull` | Download pre-quantized models |
| `list` | List downloaded models |

Run `chatllm <command> --help` for detailed options.

## API Server Endpoints

### OpenAI API (compatible)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completions (streaming supported) |
| `/v1/embeddings` | POST | Generate embeddings |
| `/v1/models` | GET | List available models |

### Ollama API (compatible)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chat` | POST | Chat completions |
| `/api/tags` | GET | List models |
| `/api/version` | GET | Version info |
| `/api/ps` | GET | Running models |

### llama.cpp API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/props` | GET | Server properties |
| `/slots` | GET | Slot information |

## Model Registry

The `pull` command downloads pre-quantized models from ModelScope:

```bash
# Model specification format
chatllm pull <model_name>[:<variant>][:<quantization>]

# Examples
chatllm pull qwen3           # qwen3:1.7b:q8 (default)
chatllm pull qwen3:4b        # qwen3:4b:q8
chatllm pull llama3.1:8b:q4_1

# Switch to HuggingFace
chatllm pull --registry huggingface qwen3
```

Models are stored in `~/.chatllm/models/`.

## Configuration

Models are stored in the user's home directory:

| Platform | Path |
|----------|------|
| Windows | `%USERPROFILE%\.chatllm\models\` |
| macOS/Linux | `~/.chatllm/models/` |

## Building

### Basic Build

```bash
zig build                        # Debug build
zig build -Doptimize=ReleaseFast # Release build
```

### Build Options

| Option | Description |
|--------|-------------|
| `-Doptimize=ReleaseFast` | Optimized release build |
| `-Dcuda=true` | Enable CUDA backend (NVIDIA) |
| `-Dvulkan=true` | Enable Vulkan backend |
| `-Dmetal=true` | Enable Metal backend (macOS) |
| `-Dchatllm_path=<path>` | Custom chatllm.cpp path |
| `-Dtarget=<triple>` | Cross-compile target |

### Examples

```bash
# macOS with Metal
zig build -Doptimize=ReleaseFast -Dmetal=true

# NVIDIA GPU support
zig build -Doptimize=ReleaseFast -Dcuda=true

# Cross-compile for Linux
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
```

### Running Tests

```bash
zig build test
```

## Project Structure

```
chatllm.zig/
├── src/
│   ├── main.zig              # CLI entry point
│   └── commands/
│       ├── chat.zig          # Interactive chat
│       ├── run.zig           # Single prompt
│       ├── serve.zig         # API server
│       ├── embedding.zig     # Embeddings
│       ├── pull.zig          # Model download
│       └── list.zig          # List models
├── chatllm.cpp.zig/
│   └── chatllm.zig           # Zig bindings for chatllm.cpp
├── chatllm.cpp/              # chatllm.cpp submodule
├── build.zig                 # Main build file
├── build.zig.zon             # Package manifest
├── build_chatllm.zig         # chatllm.cpp build integration
├── docs/                     # Documentation
└── examples/                 # Example code
```

## Tested Platforms

| Platform | Architecture | Status |
|----------|--------------|--------|
| Windows 11 | x86_64 | ✅ |
| macOS 14+ | aarch64 (Apple Silicon) | ✅ |
| macOS 14+ | x86_64 (Intel) | ✅ |
| Ubuntu 22.04 | x86_64 | ✅ |
| Ubuntu 22.04 | aarch64 | ✅ |

## Backend Support

| Backend | Status | Platforms |
|---------|--------|-----------|
| CPU | ✅ Stable | All |
| Metal | ✅ Stable | macOS |
| CUDA | 🔧 Experimental | Linux, Windows |
| Vulkan | 🔧 Experimental | All |
| OpenCL | 📋 Planned | - |

## Library Usage

```zig
const std = @import("std");
const chatllm = @import("chatllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize
    _ = chatllm.ChatLLM.globalInit();

    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Configure
    try llm.appendParam("-m");
    try llm.appendParam("model.bin");

    // Set up callbacks
    const Ctx = struct {
        pub fn onPrint(_: *@This(), ptype: chatllm.PrintType, text: []const u8) void {
            if (ptype == .chat_chunk) {
                std.debug.print("{s}", .{text});
            }
        }
        pub fn onEnd(_: *@This()) void {
            std.debug.print("\n", .{});
        }
    };

    var ctx = Ctx{};
    var callback = chatllm.CallbackContext(*Ctx){
        .user_data = &ctx,
        .print_fn = Ctx.onPrint,
        .end_fn = Ctx.onEnd,
    };

    try llm.startWithContext(*Ctx, &callback);
    try llm.userInput("Hello, world!");
}
```

See the [examples/](examples/) directory for more usage patterns.

## Roadmap

- [x] Core CLI (chat, run, serve, embedding)
- [x] Model registry and download
- [x] OpenAI-compatible API server
- [x] Ollama-compatible API endpoints
- [x] Zig library bindings
- [ ] GPU acceleration (CUDA, Metal, Vulkan)
- [ ] Vision model support (Qwen-VL, etc.)
- [ ] Audio model support (Qwen-Audio)
- [ ] WebSocket API
- [ ] RAG integration
- [ ] Function calling / tool use

## Credits

- [chatllm.cpp](https://github.com/jzxxx/chatllm.cpp) — The underlying C++ inference engine
- [GGML](https://github.com/ggerganov/ggml) — Tensor library for ML
- [Zig](https://ziglang.org) — The programming language

## License

MIT License — see [LICENSE](LICENSE) for details.

chatllm.cpp is licensed under the MIT License.
