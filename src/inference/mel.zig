// Mel spectrogram: raw PCM → mel-frequency features
// The ear of the system. Decomposes audio into frequency bands
// that match human perception — low frequencies get fine resolution,
// high frequencies get coarse. Same transform your cochlea does.
//
// Pipeline: samples → window → FFT → power spectrum → mel filterbank → log
//
// Streaming: push samples in, pop mel frames out.
// 160 samples in (10ms @ 16kHz) → 1 mel frame out (128 bins).

const std = @import("std");
const math = @import("math.zig");

/// FFT size (next power of 2 above window_size)
const FFT_N = 512;
const FFT_LOG2 = 9;

/// Audio parameters matching Qwen3-ASR / Whisper
pub const Config = struct {
    sample_rate: usize = 16000,
    n_fft: usize = FFT_N,
    hop_length: usize = 160, // 10ms
    win_length: usize = 400, // 25ms
    n_mels: usize = 128,

    fn fft_bins(self: Config) usize {
        return self.n_fft / 2 + 1; // 257
    }
};

/// Streaming mel spectrogram processor.
/// Push PCM samples, pop mel frames.
pub const MelProcessor = struct {
    config: Config,

    // precomputed tables
    window: [400]f32, // Hann window
    filterbank: []f32, // [n_mels × fft_bins] mel filterbank
    bit_rev: [FFT_N]u16, // bit-reversal permutation

    // streaming state
    sample_buf: [800]f32, // ring buffer for overlap (2× win_length)
    buf_pos: usize,
    samples_since_frame: usize,

    // FFT scratch
    fft_re: [FFT_N]f32,
    fft_im: [FFT_N]f32,

    // output scratch
    power: [257]f32, // FFT_N/2 + 1
    mel_out: [128]f32,

    pub fn init(alloc: std.mem.Allocator) !MelProcessor {
        const config = Config{};
        var self = MelProcessor{
            .config = config,
            .window = undefined,
            .filterbank = try alloc.alloc(f32, config.n_mels * config.fft_bins()),
            .bit_rev = undefined,
            .sample_buf = [_]f32{0} ** 800,
            .buf_pos = 0,
            .samples_since_frame = 0,
            .fft_re = undefined,
            .fft_im = undefined,
            .power = undefined,
            .mel_out = undefined,
        };

        // Hann window: 0.5 * (1 - cos(2π * n / (N-1)))
        for (0..config.win_length) |n| {
            const phase = 2.0 * std.math.pi * @as(f32, @floatFromInt(n)) /
                @as(f32, @floatFromInt(config.win_length - 1));
            self.window[n] = 0.5 * (1.0 - @cos(phase));
        }

        // bit-reversal permutation for in-place FFT
        for (0..FFT_N) |i| {
            var rev: u16 = 0;
            var val: u16 = @intCast(i);
            for (0..FFT_LOG2) |_| {
                rev = (rev << 1) | (val & 1);
                val >>= 1;
            }
            self.bit_rev[i] = rev;
        }

        // mel filterbank: triangular filters on mel scale
        computeFilterbank(self.filterbank, config);

        return self;
    }

    pub fn deinit(self: *MelProcessor, alloc: std.mem.Allocator) void {
        alloc.free(self.filterbank);
    }

    /// Push raw PCM samples (i16 → f32 normalization).
    /// Call popFrame() after each push to check for output.
    pub fn pushSamples(self: *MelProcessor, samples: []const i16) void {
        for (samples) |s| {
            self.sample_buf[self.buf_pos] = @as(f32, @floatFromInt(s)) / 32768.0;
            self.buf_pos = (self.buf_pos + 1) % self.sample_buf.len;
            self.samples_since_frame += 1;
        }
    }

    /// Push pre-normalized f32 samples.
    pub fn pushF32(self: *MelProcessor, samples: []const f32) void {
        for (samples) |s| {
            self.sample_buf[self.buf_pos] = s;
            self.buf_pos = (self.buf_pos + 1) % self.sample_buf.len;
            self.samples_since_frame += 1;
        }
    }

    /// Pop a mel frame if enough samples accumulated (hop_length).
    /// Returns true if a frame was produced.
    pub fn popFrame(self: *MelProcessor, out: *[128]f32) bool {
        if (self.samples_since_frame < self.config.hop_length) return false;
        self.samples_since_frame -= self.config.hop_length;

        // extract windowed frame from ring buffer
        // the frame ends at buf_pos - samples_since_frame
        const frame_end = (self.buf_pos + self.sample_buf.len - self.samples_since_frame) % self.sample_buf.len;
        const win_len = self.config.win_length;

        // apply window and zero-pad to FFT_N
        @memset(&self.fft_re, 0);
        @memset(&self.fft_im, 0);
        for (0..win_len) |n| {
            const idx = (frame_end + self.sample_buf.len - win_len + n) % self.sample_buf.len;
            self.fft_re[n] = self.sample_buf[idx] * self.window[n];
        }

        // FFT
        self.fft();

        // power spectrum: |X[k]|² for k = 0..N/2
        const bins = self.config.fft_bins();
        for (0..bins) |k| {
            self.power[k] = self.fft_re[k] * self.fft_re[k] + self.fft_im[k] * self.fft_im[k];
        }

        // mel filterbank: mel = filterbank @ power
        for (0..self.config.n_mels) |m| {
            const fb_row = self.filterbank[m * bins ..][0..bins];
            var sum: f32 = 0;
            sum = math.dotProduct(fb_row, self.power[0..bins]);
            // log mel (clamp to avoid log(0))
            out[m] = @log(@max(sum, 1e-10));
        }
        return true;
    }

    /// In-place radix-2 Cooley-Tukey FFT.
    fn fft(self: *MelProcessor) void {
        // bit-reversal permutation
        for (0..FFT_N) |i| {
            const j = self.bit_rev[i];
            if (i < j) {
                std.mem.swap(f32, &self.fft_re[i], &self.fft_re[j]);
                std.mem.swap(f32, &self.fft_im[i], &self.fft_im[j]);
            }
        }

        // butterfly stages
        var half: usize = 1;
        for (0..FFT_LOG2) |_| {
            const step = half * 2;
            const angle_step = -std.math.pi / @as(f32, @floatFromInt(half));
            var j: usize = 0;
            while (j < FFT_N) : (j += step) {
                for (0..half) |k| {
                    const angle = angle_step * @as(f32, @floatFromInt(k));
                    const wr = @cos(angle);
                    const wi = @sin(angle);
                    const a = j + k;
                    const b = a + half;
                    const tre = wr * self.fft_re[b] - wi * self.fft_im[b];
                    const tim = wr * self.fft_im[b] + wi * self.fft_re[b];
                    self.fft_re[b] = self.fft_re[a] - tre;
                    self.fft_im[b] = self.fft_im[a] - tim;
                    self.fft_re[a] += tre;
                    self.fft_im[a] += tim;
                }
            }
            half = step;
        }
    }
};

/// Hz to mel (HTK formula): mel = 2595 * log10(1 + f/700)
fn hzToMel(hz: f32) f32 {
    return 2595.0 * std.math.log10(1.0 + hz / 700.0);
}

/// Mel to Hz: f = 700 * (10^(mel/2595) - 1)
fn melToHz(mel: f32) f32 {
    return 700.0 * (std.math.pow(f32, 10.0, mel / 2595.0) - 1.0);
}

/// Compute triangular mel filterbank.
/// out: [n_mels × fft_bins] row-major, each row is one triangular filter.
fn computeFilterbank(out: []f32, config: Config) void {
    const n_mels = config.n_mels;
    const bins = config.fft_bins();
    const sr: f32 = @floatFromInt(config.sample_rate);
    const n_fft: f32 = @floatFromInt(config.n_fft);

    @memset(out, 0);

    const mel_low = hzToMel(0);
    const mel_high = hzToMel(sr / 2.0);

    // n_mels + 2 points linearly spaced in mel, converted back to Hz
    var mel_points: [130]f32 = undefined; // max 128 + 2
    const n_points = n_mels + 2;
    for (0..n_points) |i| {
        const mel = mel_low + (mel_high - mel_low) * @as(f32, @floatFromInt(i)) /
            @as(f32, @floatFromInt(n_points - 1));
        mel_points[i] = melToHz(mel);
    }

    // convert Hz to FFT bin indices (fractional)
    var bin_points: [130]f32 = undefined;
    for (0..n_points) |i| {
        bin_points[i] = mel_points[i] * n_fft / sr;
    }

    // triangular filters
    for (0..n_mels) |m| {
        const left = bin_points[m];
        const center = bin_points[m + 1];
        const right = bin_points[m + 2];

        for (0..bins) |k| {
            const freq: f32 = @floatFromInt(k);
            var val: f32 = 0;
            if (freq >= left and freq <= center and center > left) {
                val = (freq - left) / (center - left);
            } else if (freq > center and freq <= right and right > center) {
                val = (right - freq) / (right - center);
            }
            out[m * bins + k] = val;
        }
    }
}

/// Batch mel spectrogram: process entire audio buffer at once.
/// Returns n_frames mel frames in out (row-major, [n_frames × n_mels]).
pub fn melSpectrogram(
    alloc: std.mem.Allocator,
    samples: []const f32,
    config: Config,
) !struct { frames: []f32, n_frames: usize } {
    var proc = try MelProcessor.init(alloc);
    defer proc.deinit(alloc);

    const n_frames = if (samples.len >= config.win_length)
        (samples.len - config.win_length) / config.hop_length + 1
    else
        0;

    const frames = try alloc.alloc(f32, n_frames * config.n_mels);
    var frame_idx: usize = 0;

    proc.pushF32(samples);
    // reset to process from beginning
    proc.buf_pos = samples.len % proc.sample_buf.len;
    proc.samples_since_frame = samples.len;

    while (frame_idx < n_frames) {
        var mel_frame: [128]f32 = undefined;
        // manually compute each frame
        const frame_start = frame_idx * config.hop_length;
        @memset(&proc.fft_re, 0);
        @memset(&proc.fft_im, 0);
        for (0..config.win_length) |n| {
            if (frame_start + n < samples.len) {
                proc.fft_re[n] = samples[frame_start + n] * proc.window[n];
            }
        }
        proc.fft();
        const bins = config.fft_bins();
        for (0..bins) |k| {
            proc.power[k] = proc.fft_re[k] * proc.fft_re[k] + proc.fft_im[k] * proc.fft_im[k];
        }
        for (0..config.n_mels) |m| {
            const fb_row = proc.filterbank[m * bins ..][0..bins];
            const sum = math.dotProduct(fb_row, proc.power[0..bins]);
            mel_frame[m] = @log(@max(sum, 1e-10));
        }
        @memcpy(frames[frame_idx * config.n_mels ..][0..config.n_mels], &mel_frame);
        frame_idx += 1;
    }

    return .{ .frames = frames, .n_frames = n_frames };
}
