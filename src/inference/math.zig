// Math operations for transformer inference
// Adapted from camconn/llm.zig (AGPL-3.0)
//
// SIMD-vectorized: rmsNorm, softMax, swiglu, matmul, add, elementProduct, dotProduct

const std = @import("std");

/// SIMD vector type using platform-suggested width.
fn Vect(comptime T: type) type {
    const len = comptime std.simd.suggestVectorLength(T) orelse 8;
    return @Vector(len, T);
}

fn vectLen(comptime T: type) usize {
    return @typeInfo(T).vector.len;
}

// ============================================================
// RMS Normalization
// ============================================================

/// RMS Normalize: out = (x * y) / rms(x)
pub fn rmsNorm(out: []f32, x: []const f32, y: []const f32) void {
    std.debug.assert(x.len == y.len and y.len == out.len);

    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;

    var sum: f32 = 0;
    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        sum += @reduce(.Add, xs * xs);
    }
    for (leftover..x.len) |i| sum += x[i] * x[i];

    const rms = std.math.sqrt(sum / @as(f32, @floatFromInt(x.len)) + 1e-6);
    const divisor: Vec = @splat(rms);

    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        const ys: Vec = y[idx..][0..vl].*;
        out[idx..][0..vl].* = (xs * ys) / divisor;
    }
    for (leftover..x.len) |i| out[i] = (x[i] * y[i]) / rms;
}

// ============================================================
// Softmax
// ============================================================

/// Safe softmax in-place.
pub fn softMax(x: []f32) void {
    std.debug.assert(x.len > 0);

    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;

    // Find max
    var max_val: f32 = x[0];
    for (x[1..]) |v| max_val = @max(max_val, v);

    // exp and sum
    var sum: f32 = 0;
    const max_v: Vec = @splat(max_val);
    for (0..chunks) |i| {
        const idx = i * vl;
        const vals: Vec = x[idx..][0..vl].*;
        const exp = @exp(vals - max_v);
        sum += @reduce(.Add, exp);
        x[idx..][0..vl].* = exp;
    }
    for (leftover..x.len) |i| {
        const val = @exp(x[i] - max_val);
        sum += val;
        x[i] = val;
    }

    // Normalize
    const sumv: Vec = @splat(sum);
    for (0..chunks) |i| {
        const idx = i * vl;
        const vals: Vec = x[idx..][0..vl].*;
        x[idx..][0..vl].* = vals / sumv;
    }
    for (leftover..x.len) |i| x[i] /= sum;
}

// ============================================================
// SwiGLU activation
// ============================================================

/// SwiGLU: x = x * sigmoid(x) = x / (1 + exp(-x))
pub fn swiglu(x: []f32) void {
    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;
    const ones: Vec = @splat(@as(f32, 1));

    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        x[idx..][0..vl].* = xs / (ones + @exp(-xs));
    }
    for (leftover..x.len) |i| {
        x[i] = x[i] / (1 + std.math.exp(-x[i]));
    }
}

// ============================================================
// Vector operations
// ============================================================

/// Element-wise add: out = x + y
pub fn add(out: []f32, x: []const f32, y: []const f32) void {
    std.debug.assert(x.len == y.len and x.len == out.len);
    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;

    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        const ys: Vec = y[idx..][0..vl].*;
        out[idx..][0..vl].* = xs + ys;
    }
    for (leftover..x.len) |i| out[i] = x[i] + y[i];
}

/// Element-wise multiply: out = x * y
pub fn elementProduct(out: []f32, x: []const f32, y: []const f32) void {
    std.debug.assert(x.len == y.len and x.len == out.len);
    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;

    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        const ys: Vec = y[idx..][0..vl].*;
        out[idx..][0..vl].* = xs * ys;
    }
    for (leftover..x.len) |i| out[i] = x[i] * y[i];
}

/// Dot product of two vectors.
pub fn dotProduct(x: []const f32, y: []const f32) f32 {
    std.debug.assert(x.len == y.len);
    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = x.len / vl;
    const leftover = chunks * vl;

    var sum: f32 = 0;
    for (0..chunks) |i| {
        const idx = i * vl;
        const xs: Vec = x[idx..][0..vl].*;
        const ys: Vec = y[idx..][0..vl].*;
        sum += @reduce(.Add, xs * ys);
    }
    for (leftover..x.len) |i| sum += x[i] * y[i];
    return sum;
}

// ============================================================
// Matrix-vector multiply
// ============================================================

/// Matrix-vector multiply: out[row] = dot(m[row], x) for each row.
/// m is (rows x cols) in row-major order.
pub fn matmul(out: []f32, m: []const f32, x: []const f32, rows: usize, cols: usize) void {
    std.debug.assert(out.len == rows);
    std.debug.assert(x.len == cols);
    std.debug.assert(m.len == rows * cols);

    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);
    const chunks = cols / vl;
    const leftover = chunks * vl;

    for (0..rows) |row| {
        const m_off = row * cols;
        var sum: f32 = 0;
        for (0..chunks) |c| {
            const idx = c * vl;
            const xs: Vec = x[idx..][0..vl].*;
            const ms: Vec = m[m_off + idx ..][0..vl].*;
            sum += @reduce(.Add, xs * ms);
        }
        for (leftover..cols) |i| sum += x[i] * m[m_off + i];
        out[row] = sum;
    }
}

// ============================================================
// Q8_0 quantized matrix-vector multiply
// ============================================================

pub const Q80Block = extern struct {
    scale: u16, // f16 stored as u16
    weights: [32]i8,
};

/// Matrix-vector multiply for Q8_0 quantized weights.
/// m has (rows * cols/32) blocks, x has (cols/32) blocks.
pub fn matmulQ80(out: []f32, m: []const Q80Block, x: []const Q80Block, rows: usize, cols: usize) void {
    const IVec = @Vector(32, i32);
    const block_size = 32;
    const col_blocks = cols / block_size;

    for (0..rows) |row| {
        const m_off = row * col_blocks;
        var sum: f32 = 0;
        for (0..col_blocks) |n| {
            const x_block = x[n];
            const m_block = m[m_off + n];
            const xs: IVec = x_block.weights;
            const ms: IVec = m_block.weights;
            const x_scale: f32 = @as(f16, @bitCast(x_block.scale));
            const m_scale: f32 = @as(f16, @bitCast(m_block.scale));
            const prod = xs * ms;
            const pre_sum: f32 = @floatFromInt(@reduce(.Add, prod));
            sum += pre_sum * x_scale * m_scale;
        }
        out[row] = sum;
    }
}

/// Quantize f32 values to Q8_0 blocks.
pub fn quantizeQ80(input: []const f32, blocks: []Q80Block) void {
    const block_size = 32;
    std.debug.assert(input.len % block_size == 0);
    std.debug.assert(input.len / block_size == blocks.len);

    for (0..blocks.len) |i| {
        const idx = i * block_size;
        const elems = input[idx..][0..block_size];

        // Find max absolute value
        var amax: f32 = 0;
        for (elems) |e| amax = @max(amax, @abs(e));

        const scale = amax / 127.0;
        const scale_f16: f16 = @floatCast(scale);
        blocks[i].scale = @bitCast(scale_f16);
        const inv_scale: f32 = if (scale == 0) 0 else 1.0 / scale;

        for (0..block_size) |j| {
            const scaled = elems[j] * inv_scale;
            const rounded = std.math.round(std.math.clamp(scaled, -128, 127));
            blocks[i].weights[j] = @intFromFloat(rounded);
        }
    }
}

/// Dequantize Q8_0 blocks to f32.
pub fn dequantizeQ80(input: []const Q80Block, out: []f32) void {
    const block_size = 32;
    for (0..input.len) |i| {
        const block = input[i];
        const scale: f32 = @as(f16, @bitCast(block.scale));
        const idx = block_size * i;
        for (0..block_size) |j| {
            out[idx + j] = @as(f32, @floatFromInt(@as(i32, block.weights[j]))) * scale;
        }
    }
}

// ============================================================
// Q4_K dequantization (for loading Q4_K_M model weights)
// ============================================================

pub const QK_K = 256;
pub const K_SCALE_SIZE = 12;

pub const Q4KBlock = extern struct {
    agg: extern struct {
        d: u16,
        dmin: u16,
    },
    scale: [K_SCALE_SIZE]u8,
    weights: [@divExact(QK_K, 2)]u8,
};

inline fn getScaleMinK4(j: usize, q: *const [K_SCALE_SIZE]u8) struct { u8, u8 } {
    if (j < 4) {
        return .{ q[j] & 0x3f, q[j + 4] & 0x3f };
    } else {
        return .{
            (q[j + 4] & 0x0f) | ((q[j - 4] >> 6) << 4),
            (q[j + 4] >> 4) | ((q[j] >> 6) << 4),
        };
    }
}

/// Dequantize Q4_K blocks to f32.
pub fn dequantizeQ4K(input: []const Q4KBlock, out: []f32) void {
    for (0.., input) |i, *block| {
        const out_block = out[i * QK_K ..][0..QK_K];
        const d: f32 = @as(f16, @bitCast(block.agg.d));
        const min: f32 = @as(f16, @bitCast(block.agg.dmin));

        var is: usize = 0;
        for (0..@divExact(QK_K, 64)) |jj| {
            const j = jj * 64;
            const q = block.weights[jj * 32 ..][0..32];

            const sc1, const m1 = getScaleMinK4(is + 0, &block.scale);
            const scale1 = d * @as(f32, @floatFromInt(sc1));
            const min1 = min * @as(f32, @floatFromInt(m1));
            const sc2, const m2 = getScaleMinK4(is + 1, &block.scale);
            const scale2 = d * @as(f32, @floatFromInt(sc2));
            const min2 = min * @as(f32, @floatFromInt(m2));

            for (0..32) |l| {
                out_block[j + l] = scale1 * @as(f32, @floatFromInt(q[l] & 0x0f)) - min1;
            }
            for (0..32) |l| {
                out_block[j + l + 32] = scale2 * @as(f32, @floatFromInt(q[l] >> 4)) - min2;
            }
            is += 2;
        }
    }
}

/// Q6_K block for dequantization.
pub const Q6KBlock = extern struct {
    ql: [@divExact(QK_K, 2)]u8, // lower 4 bits of quantized weights
    qh: [@divExact(QK_K, 4)]u8, // upper 2 bits of quantized weights
    scales: [@divExact(QK_K, 16)]i8, // block scales
    d: u16, // super-block scale (f16)
};

/// Dequantize Q6_K blocks to f32.
pub fn dequantizeQ6K(input: []const Q6KBlock, out: []f32) void {
    for (0.., input) |i, *block| {
        const out_block = out[i * QK_K ..][0..QK_K];
        const d: f32 = @as(f16, @bitCast(block.d));

        for (0..@divExact(QK_K, 128)) |idx| {
            const ql = block.ql[idx * 64 ..][0..64];
            const qh = block.qh[idx * 32 ..][0..32];

            for (0..2) |n| {
                const shift: u3 = @intCast(n * 2);
                for (0..2) |m| {
                    const sc_idx = idx * 4 + n * 2 + m;
                    const sc: f32 = @floatFromInt(block.scales[sc_idx]);
                    const base = idx * 128 + n * 64 + m * 32;

                    for (0..16) |l| {
                        const q_lo: u8 = if (m == 0) ql[l] & 0x0f else ql[l] >> 4;
                        const q_hi: u8 = (qh[l] >> shift) & 0x03;
                        const q: i8 = @intCast(@as(u8, q_lo | (q_hi << 4)));
                        out_block[base + l] = d * sc * @as(f32, @floatFromInt(q - 32));
                    }
                    for (0..16) |l| {
                        const q_lo: u8 = if (m == 0) ql[l + 16] & 0x0f else ql[l + 16] >> 4;
                        const q_hi: u8 = (qh[l + 16] >> shift) & 0x03;
                        const q: i8 = @intCast(@as(u8, q_lo | (q_hi << 4)));
                        out_block[base + l + 16] = d * sc * @as(f32, @floatFromInt(q - 32));
                    }
                }
            }
        }
    }
}

// ============================================================
// Fused dot products: quantized weights × f32 vector
// No intermediate f32 buffer needed — single pass, cache-friendly.
// ============================================================

/// Dot product: Q4_K blocks × f32 vector. One row of cols elements.
pub fn dotQ4K(blocks: []const Q4KBlock, x: []const f32) f32 {
    @setFloatMode(.optimized);
    const Vec = comptime Vect(f32);
    const vl = comptime vectLen(Vec);

    var sum: f32 = 0;
    for (0.., blocks) |bi, *block| {
        const d: f32 = @as(f16, @bitCast(block.agg.d));
        const dmin: f32 = @as(f16, @bitCast(block.agg.dmin));
        const xb = x[bi * QK_K ..][0..QK_K];

        var is: usize = 0;
        for (0..@divExact(QK_K, 64)) |jj| {
            const j = jj * 64;
            const q = block.weights[jj * 32 ..][0..32];

            const sc1, const m1 = getScaleMinK4(is + 0, &block.scale);
            const scale1 = d * @as(f32, @floatFromInt(sc1));
            const min1 = dmin * @as(f32, @floatFromInt(m1));
            const sc2, const m2 = getScaleMinK4(is + 1, &block.scale);
            const scale2 = d * @as(f32, @floatFromInt(sc2));
            const min2 = dmin * @as(f32, @floatFromInt(m2));

            // Low nibbles × x[j..j+32], accumulate scale1*Σ(q*x) - min1*Σ(x)
            var dot1: f32 = 0;
            var xsum1: f32 = 0;
            const chunks1 = 32 / vl;
            for (0..chunks1) |ci| {
                const idx = j + ci * vl;
                const xv: Vec = xb[idx..][0..vl].*;
                // Unpack low nibbles to f32
                var qv: Vec = undefined;
                inline for (0..vl) |vi| {
                    qv[vi] = @floatFromInt(q[ci * vl + vi] & 0x0f);
                }
                dot1 += @reduce(.Add, qv * xv);
                xsum1 += @reduce(.Add, xv);
            }
            sum += scale1 * dot1 - min1 * xsum1;

            // High nibbles × x[j+32..j+64]
            var dot2: f32 = 0;
            var xsum2: f32 = 0;
            for (0..chunks1) |ci| {
                const idx = j + 32 + ci * vl;
                const xv: Vec = xb[idx..][0..vl].*;
                var qv: Vec = undefined;
                inline for (0..vl) |vi| {
                    qv[vi] = @floatFromInt(q[ci * vl + vi] >> 4);
                }
                dot2 += @reduce(.Add, qv * xv);
                xsum2 += @reduce(.Add, xv);
            }
            sum += scale2 * dot2 - min2 * xsum2;

            is += 2;
        }
    }
    return sum;
}

/// Dot product: Q6_K blocks × f32 vector. One row of cols elements.
pub fn dotQ6K(blocks: []const Q6KBlock, x: []const f32) f32 {
    @setFloatMode(.optimized);
    var sum: f32 = 0;
    for (0.., blocks) |bi, *block| {
        const d: f32 = @as(f16, @bitCast(block.d));
        const xb = x[bi * QK_K ..][0..QK_K];

        for (0..@divExact(QK_K, 128)) |idx| {
            const ql = block.ql[idx * 64 ..][0..64];
            const qh = block.qh[idx * 32 ..][0..32];

            for (0..2) |n| {
                const shift: u3 = @intCast(n * 2);
                for (0..2) |m| {
                    const sc_idx = idx * 4 + n * 2 + m;
                    const sc: f32 = @floatFromInt(block.scales[sc_idx]);
                    const base = idx * 128 + n * 64 + m * 32;
                    const d_sc = d * sc;

                    var dot: f32 = 0;
                    for (0..16) |l| {
                        const q_lo: u8 = if (m == 0) ql[l] & 0x0f else ql[l] >> 4;
                        const q_hi: u8 = (qh[l] >> shift) & 0x03;
                        const q: i8 = @intCast(@as(u8, q_lo | (q_hi << 4)));
                        dot += @as(f32, @floatFromInt(@as(i32, q) - 32)) * xb[base + l];
                    }
                    for (0..16) |l| {
                        const q_lo: u8 = if (m == 0) ql[l + 16] & 0x0f else ql[l + 16] >> 4;
                        const q_hi: u8 = (qh[l + 16] >> shift) & 0x03;
                        const q: i8 = @intCast(@as(u8, q_lo | (q_hi << 4)));
                        dot += @as(f32, @floatFromInt(@as(i32, q) - 32)) * xb[base + l + 16];
                    }
                    sum += d_sc * dot;
                }
            }
        }
    }
    return sum;
}

// ============================================================
// Multi-threaded matrix-vector multiply
// ============================================================

/// Thread-parallel matmul: splits rows across threads.
/// Works for any row-compute function via the MatmulJob abstraction.
pub fn matmulParallel(
    out: []f32,
    rows: usize,
    comptime RowFn: type,
    ctx: RowFn,
    n_threads: usize,
) void {
    if (n_threads <= 1 or rows < n_threads * 4) {
        // Not worth threading for small matrices
        for (0..rows) |row| {
            out[row] = ctx.computeRow(row);
        }
        return;
    }

    const actual_threads = @min(n_threads, MAX_THREADS);
    const rows_per_thread = rows / actual_threads;
    var threads: [MAX_THREADS]?std.Thread = [_]?std.Thread{null} ** MAX_THREADS;

    // Spawn worker threads for all chunks except the last
    for (0..actual_threads - 1) |ti| {
        const start = ti * rows_per_thread;
        const end = (ti + 1) * rows_per_thread;
        threads[ti] = std.Thread.spawn(.{}, threadedRowCompute, .{ out, start, end, ctx }) catch null;
    }

    // Run last chunk on calling thread (avoids spawn overhead)
    {
        const start = (actual_threads - 1) * rows_per_thread;
        threadedRowCompute(out, start, rows, ctx);
    }

    // Join worker threads
    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.join();
            t.* = null;
        }
    }
}

const MAX_THREADS = 8;

fn threadedRowCompute(
    out: []f32,
    start: usize,
    end: usize,
    ctx: anytype,
) void {
    @setFloatMode(.optimized);
    for (start..end) |row| {
        out[row] = ctx.computeRow(row);
    }
}

/// Job context for Q4_K matmul.
pub const Q4KMatmulCtx = struct {
    data: []const Q4KBlock,
    x: []const f32,
    cols: usize,

    pub fn computeRow(self: Q4KMatmulCtx, row: usize) f32 {
        const blocks_per_row = self.cols / QK_K;
        const row_blocks = self.data[row * blocks_per_row ..][0..blocks_per_row];
        return dotQ4K(row_blocks, self.x);
    }
};

/// Job context for Q6_K matmul.
pub const Q6KMatmulCtx = struct {
    data: []const Q6KBlock,
    x: []const f32,
    cols: usize,

    pub fn computeRow(self: Q6KMatmulCtx, row: usize) f32 {
        const blocks_per_row = self.cols / QK_K;
        const row_blocks = self.data[row * blocks_per_row ..][0..blocks_per_row];
        return dotQ6K(row_blocks, self.x);
    }
};

/// Fused f16→f32 dot product: no intermediate buffer needed.
pub fn dotF16(weights: []const f16, x: []const f32) f32 {
    std.debug.assert(weights.len == x.len);
    const Vec16 = @Vector(16, f32);
    const vl = 16;
    const chunks = weights.len / vl;
    const leftover = chunks * vl;

    var sum: f32 = 0;
    for (0..chunks) |i| {
        const idx = i * vl;
        // Convert f16 to f32 in register
        var wv: Vec16 = undefined;
        inline for (0..vl) |j| {
            wv[j] = @as(f32, @floatCast(weights[idx + j]));
        }
        const xv: Vec16 = x[idx..][0..vl].*;
        sum += @reduce(.Add, wv * xv);
    }
    for (leftover..weights.len) |i| {
        sum += @as(f32, @floatCast(weights[i])) * x[i];
    }
    return sum;
}

/// Job context for f16 matmul (fused f16→f32 dot product per row).
pub const F16MatmulCtx = struct {
    data: []const f16,
    x: []const f32,
    cols: usize,

    pub fn computeRow(self: F16MatmulCtx, row: usize) f32 {
        const m_off = row * self.cols;
        return dotF16(self.data[m_off..][0..self.cols], self.x);
    }
};

/// Job context for f32 matmul.
pub const F32MatmulCtx = struct {
    data: []const f32,
    x: []const f32,
    cols: usize,

    pub fn computeRow(self: F32MatmulCtx, row: usize) f32 {
        const m_off = row * self.cols;
        return dotProduct(self.data[m_off..][0..self.cols], self.x);
    }
};

/// Job context for Q8_0 matmul.
pub const Q80MatmulCtx = struct {
    data: []const Q80Block,
    x_quant: []const Q80Block,
    cols: usize,

    pub fn computeRow(self: Q80MatmulCtx, row: usize) f32 {
        const IVec = @Vector(32, i32);
        const block_size = 32;
        const col_blocks = self.cols / block_size;
        const m_off = row * col_blocks;

        var sum: f32 = 0;
        for (0..col_blocks) |n| {
            const x_block = self.x_quant[n];
            const m_block = self.data[m_off + n];
            const xs: IVec = x_block.weights;
            const ms: IVec = m_block.weights;
            const x_scale: f32 = @as(f16, @bitCast(x_block.scale));
            const m_scale: f32 = @as(f16, @bitCast(m_block.scale));
            const prod = xs * ms;
            const pre_sum: f32 = @floatFromInt(@reduce(.Add, prod));
            sum += pre_sum * x_scale * m_scale;
        }
        return sum;
    }
};

/// Detect number of CPU cores for threading.
pub fn cpuCount() usize {
    return std.Thread.getCpuCount() catch 1;
}
