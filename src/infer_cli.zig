//! Standalone CLI entry for the GGUF inference engine.
//!
//! Re-exports `inference/test_infer.zig`'s `main` from a root in `src/` so the
//! inference modules' `../compat.zig` imports resolve (module root = src/).
//! Run: `zig build infer -- <model.gguf> "<prompt>"`.
pub const main = @import("inference/test_infer.zig").main;
