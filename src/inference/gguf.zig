// GGUF file format parser
// Adapted from camconn/llm.zig (AGPL-3.0) and ggml-org/ggml
//
// Parses GGUF v3 files: header, metadata KV pairs, tensor info, mmap'd tensor data.

const std = @import("std");
const compat = @import("../compat.zig");

const page_size = std.heap.page_size_min;
const Reader = *std.Io.Reader;

pub const Error = error{
    FileError,
    Alloc,
    Format,
    EOF,
    Unknown,
};

// ggml_type — tensor element types
pub const Type = enum(u32) {
    // zig fmt: off
    F32     = 0,
    F16     = 1,
    Q4_0    = 2,
    Q4_1    = 3,
    Q5_0    = 6,
    Q5_1    = 7,
    Q8_0    = 8,
    Q8_1    = 9,
    Q2_K    = 10,
    Q3_K    = 11,
    Q4_K    = 12,
    Q5_K    = 13,
    Q6_K    = 14,
    Q8_K    = 15,
    I8      = 24,
    I16     = 25,
    I32     = 26,
    I64     = 27,
    F64     = 28,
    // zig fmt: on
};

// gguf_metadata_value_type
pub const MetadataType = enum(u32) {
    // zig fmt: off
    uint8   = 0,
    int8    = 1,
    uint16  = 2,
    int16   = 3,
    uint32  = 4,
    int32   = 5,
    float32 = 6,
    boolean = 7,
    string  = 8,
    array   = 9,
    uint64  = 10,
    int64   = 11,
    float64 = 12,
    // zig fmt: on
};

/// Reject a count that cannot fit in what is left of the file.
///
/// Every length and count in a GGUF file is attacker-controlled — the file is
/// downloaded, not typed. Using one to size an allocation without a bound let
/// a 2^63 string length reach the allocator, which panicked computing its
/// growth size (a crash on a malicious model) and, with safety checks off,
/// wrapped to an allocation smaller than the slice length handed straight to
/// readSliceAll.
///
/// Nothing stored in a file can be longer than the file, so the remaining byte
/// count is a sound upper bound and costs one comparison. `elem_size` is the
/// minimum on-disk footprint of one element.
/// Nesting limit for metadata values. GGUF arrays may nominally contain
/// arrays; nothing real does, and unbounded nesting is a stack-overflow
/// primitive for a downloaded file.
const max_value_depth: u8 = 8;

fn boundedCount(reader: Reader, count: u64, elem_size: u64) Error!usize {
    const remaining: u64 = reader.buffer.len -| reader.seek;
    if (elem_size != 0 and count > remaining / elem_size) return Error.Format;
    if (count > remaining) return Error.Format;
    return std.math.cast(usize, count) orelse return Error.Format;
}

pub const String = struct {
    len: u64,
    str: []u8,

    fn read(reader: Reader, alloc: std.mem.Allocator) Error!String {
        const raw_len = reader.takeInt(u64, .little) catch return Error.EOF;
        const len = try boundedCount(reader, raw_len, 1);
        const buf = alloc.alloc(u8, len) catch return Error.Alloc;
        reader.readSliceAll(buf) catch return Error.FileError;
        return .{ .len = len, .str = buf };
    }
};

pub const Array = struct {
    elem_type: MetadataType,
    len: u64,
    array: []Value,

    fn read(reader: Reader, alloc: std.mem.Allocator, depth: u8) Error!Array {
        // An array whose element type is itself `array` recurses through
        // Value.read. Each level only costs 12 bytes on disk, so a small file
        // can nest tens of thousands deep and exhaust the stack — a crash from
        // a downloaded model. Real GGUF files never nest arrays at all.
        if (depth >= max_value_depth) return Error.Format;

        const element_type = reader.takeEnum(MetadataType, .little) catch return Error.EOF;
        const raw_len = reader.takeInt(u64, .little) catch return Error.EOF;
        // Every element occupies at least one byte on disk, so an array longer
        // than the rest of the file cannot be valid. Without this the loop
        // allocates its way toward OOM before the reader finally reports EOF.
        const len = try boundedCount(reader, raw_len, 1);

        var list: std.ArrayList(Value) = .empty;
        for (0..len) |_| {
            const val = try Value.read(element_type, reader, alloc, depth + 1);
            list.append(alloc, val) catch return Error.Alloc;
        }

        return .{
            .elem_type = element_type,
            .len = len,
            .array = list.toOwnedSlice(alloc) catch return Error.Alloc,
        };
    }
};

pub const Value = union(MetadataType) {
    uint8: u8,
    int8: i8,
    uint16: u16,
    int16: i16,
    uint32: u32,
    int32: i32,
    float32: f32,
    boolean: bool,
    string: String,
    array: Array,
    uint64: u64,
    int64: i64,
    float64: f64,

    fn read(value_type: MetadataType, reader: Reader, alloc: std.mem.Allocator, depth: u8) Error!Value {
        // zig fmt: off
        return switch (value_type) {
            .uint8   => .{ .uint8   = reader.takeInt(u8, .little)  catch return Error.EOF },
            .int8    => .{ .int8    = reader.takeInt(i8, .little)  catch return Error.EOF },
            .uint16  => .{ .uint16  = reader.takeInt(u16, .little) catch return Error.EOF },
            .int16   => .{ .int16   = reader.takeInt(i16, .little) catch return Error.EOF },
            .uint32  => .{ .uint32  = reader.takeInt(u32, .little) catch return Error.EOF },
            .int32   => .{ .int32   = reader.takeInt(i32, .little) catch return Error.EOF },
            .uint64  => .{ .uint64  = reader.takeInt(u64, .little) catch return Error.EOF },
            .int64   => .{ .int64   = reader.takeInt(i64, .little) catch return Error.EOF },
            .boolean => .{ .boolean = (reader.takeInt(u8, .little) catch return Error.EOF) == 1 },
            .float32 => .{ .float32 = @bitCast(reader.takeInt(u32, .little) catch return Error.EOF) },
            .float64 => .{ .float64 = @bitCast(reader.takeInt(u64, .little) catch return Error.EOF) },
            .string  => .{ .string  = try String.read(reader, alloc) },
            .array   => .{ .array   = try Array.read(reader, alloc, depth) },
        };
        // zig fmt: on
    }
};

pub const MetadataKV = struct {
    key: String,
    value: Value,

    fn read(reader: Reader, alloc: std.mem.Allocator) Error!MetadataKV {
        const key = try String.read(reader, alloc);
        const value_type = reader.takeEnum(MetadataType, .little) catch return Error.EOF;
        const value = try Value.read(value_type, reader, alloc, 0);
        return .{ .key = key, .value = value };
    }
};

pub const GGUFHeader = struct {
    const magic_num: u32 = 0x46554747; // "GGUF" little-endian

    version: u32,
    tensor_count: u64,
    metadata_kv_count: u64,

    pub fn read(reader: Reader) Error!GGUFHeader {
        const magic = reader.takeInt(u32, .little) catch return Error.EOF;
        if (magic != magic_num) return Error.Format;
        const version = reader.takeInt(u32, .little) catch return Error.EOF;
        if (version != 3) return Error.Format;
        const tensor_count = reader.takeInt(u64, .little) catch return Error.EOF;
        const metadata_kv_count = reader.takeInt(u64, .little) catch return Error.EOF;
        return .{
            .version = version,
            .tensor_count = tensor_count,
            .metadata_kv_count = metadata_kv_count,
        };
    }
};

pub const TensorInfo = struct {
    name: String,
    dimensions: []u64,
    ggml_type: Type,
    offset: usize,

    fn read(reader: Reader, alignment: usize, alloc: std.mem.Allocator) Error!TensorInfo {
        const name = String.read(reader, alloc) catch return Error.EOF;
        const dim = reader.takeInt(u32, .little) catch return Error.EOF;
        // A malformed dimension count is a corrupt file, not a broken
        // invariant: assert() aborted the process on an attacker-supplied
        // model in a safety build, and vanished entirely in ReleaseFast.
        if (dim == 0) return Error.Format;
        // Each dimension is a u64 on disk, so dim is bounded by the remaining
        // file. Unbounded, a u32 count asked the allocator for up to 32 GiB.
        const dim_count = try boundedCount(reader, dim, @sizeOf(u64));
        const dimensions = alloc.alloc(u64, dim_count) catch return Error.Alloc;
        for (0..dim_count) |i| {
            dimensions[i] = reader.takeInt(u64, .little) catch return Error.EOF;
        }
        const ggml_type = reader.takeEnum(Type, .little) catch return Error.EOF;
        const offset: usize = @intCast(reader.takeInt(u64, .little) catch return Error.EOF);

        const aligned = alignOffset(offset, alignment);
        if (offset != aligned) return Error.FileError;

        return .{
            .name = name,
            .dimensions = dimensions,
            .ggml_type = ggml_type,
            .offset = offset,
        };
    }

    inline fn alignOffset(offset: usize, alignment: usize) usize {
        return offset + (alignment - (offset % alignment)) % alignment;
    }

    /// Total number of elements in this tensor.
    ///
    /// Saturates instead of wrapping. The dimensions come from the file, so
    /// the product is attacker-controlled: an unchecked `*=` overflowed to a
    /// *small* number, and callers size buffers off this. Saturating keeps the
    /// result implausibly large, so a bounds check downstream still rejects it
    /// rather than being handed a value that looks reasonable.
    pub fn numElements(self: TensorInfo) usize {
        var len: usize = 1;
        for (self.dimensions) |d| {
            const dv = std.math.cast(usize, d) orelse return std.math.maxInt(usize);
            len = std.math.mul(usize, len, dv) catch return std.math.maxInt(usize);
        }
        return len;
    }

    /// Get raw pointer to tensor data from mmap'd region.
    pub fn getData(self: TensorInfo, tensor_data: [*]const u8) [*]const u8 {
        return tensor_data + self.offset;
    }
};

pub const GGUFFile = struct {
    header: GGUFHeader,
    metadata: []MetadataKV,
    tensor_info: []TensorInfo,
    tensor_data_offset: usize,

    arena: std.heap.ArenaAllocator,
    fd: compat.posix.fd_t,
    mmap_ptr: []align(page_size) u8,
    file_size: usize,

    pub fn open(path: []const u8, alloc: std.mem.Allocator) !GGUFFile {
        // Open and mmap the file
        const fd = compat.posix.open(path, .{}, 0o440) catch return Error.FileError;
        errdefer compat.posix.close(fd);

        const stat = compat.posix.fstat(fd) catch return Error.FileError;
        const fsize: u64 = @intCast(stat.size);

        const mmap_type: compat.posix.MAP = .{
            .TYPE = .SHARED,
            .NORESERVE = true,
            .POPULATE = true,
        };
        const ptr = compat.posix.mmap(null, fsize, .{ .READ = true }, mmap_type, fd, 0) catch return Error.FileError;
        errdefer compat.posix.munmap(ptr);

        const madvise_flags = compat.posix.MADV.SEQUENTIAL | compat.posix.MADV.WILLNEED;
        compat.posix.madvise(ptr.ptr, fsize, madvise_flags) catch {};

        // Parse header and metadata
        var stream = std.Io.Reader.fixed(ptr);
        const reader = &stream;

        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        const header = try GGUFHeader.read(reader);

        // Read metadata
        var meta_list: std.ArrayList(MetadataKV) = .empty;
        for (0..header.metadata_kv_count) |_| {
            const kv = try MetadataKV.read(reader, a);
            meta_list.append(a, kv) catch return Error.Alloc;
        }
        const metadata = meta_list.toOwnedSlice(a) catch return Error.Alloc;

        // Get alignment
        const alignment: usize = blk: {
            if (getMetadataValue("general.alignment", metadata)) |val| {
                if (val == .uint32) {
                    // This value comes from the file. Zero makes alignOffset
                    // evaluate `offset % 0` — a divide-by-zero crash — and
                    // std.mem.alignForward below requires a power of two.
                    // Neither is a valid GGUF alignment, so reject the file
                    // rather than silently substituting a default.
                    if (val.uint32 == 0 or !std.math.isPowerOfTwo(val.uint32)) {
                        return Error.Format;
                    }
                    break :blk val.uint32;
                }
            }
            break :blk 32;
        };

        // Read tensor info
        var tensor_list: std.ArrayList(TensorInfo) = .empty;
        for (0..header.tensor_count) |_| {
            const ti = try TensorInfo.read(reader, alignment, a);
            tensor_list.append(a, ti) catch return Error.Alloc;
        }
        const tensor_info = tensor_list.toOwnedSlice(a) catch return Error.Alloc;

        // Calculate tensor data offset (aligned)
        const file_offset: usize = @intCast(stream.seek);
        const tensor_data_offset = std.mem.alignForward(usize, file_offset, alignment);

        // Every tensor offset must land inside the mapping. getData() does
        // `tensor_data + offset` with no check of its own, so an offset read
        // from a malicious file produced a pointer past the end of the mmap —
        // a segfault at best, a read of unrelated memory at worst. This is the
        // first point where both the offsets and the file size are known.
        if (tensor_data_offset > fsize) return Error.Format;
        for (tensor_info) |ti| {
            const abs = std.math.add(usize, tensor_data_offset, ti.offset) catch return Error.Format;
            if (abs > fsize) return Error.Format;
        }

        return .{
            .header = header,
            .metadata = metadata,
            .tensor_info = tensor_info,
            .tensor_data_offset = tensor_data_offset,
            .arena = arena,
            .fd = fd,
            .mmap_ptr = ptr,
            .file_size = fsize,
        };
    }

    pub fn deinit(self: *GGUFFile) void {
        _ = self.arena.reset(.free_all);
        self.arena.deinit();
        if (self.fd != -1) {
            compat.posix.munmap(self.mmap_ptr);
            compat.posix.close(self.fd);
        }
        self.fd = -1;
    }

    /// Get metadata value by key.
    pub fn getValue(self: *const GGUFFile, key: []const u8) ?Value {
        return getMetadataValue(key, self.metadata);
    }

    /// Get string metadata value.
    pub fn getString(self: *const GGUFFile, key: []const u8) ?[]const u8 {
        if (self.getValue(key)) |v| {
            if (v == .string) return v.string.str;
        }
        return null;
    }

    /// Get u32 metadata value.
    pub fn getU32(self: *const GGUFFile, key: []const u8) ?u32 {
        if (self.getValue(key)) |v| {
            if (v == .uint32) return v.uint32;
        }
        return null;
    }

    /// Get f32 metadata value.
    pub fn getF32(self: *const GGUFFile, key: []const u8) ?f32 {
        if (self.getValue(key)) |v| {
            if (v == .float32) return v.float32;
        }
        return null;
    }

    /// Get tensor info by name.
    pub fn getTensorInfo(self: *const GGUFFile, name: []const u8) ?TensorInfo {
        for (self.tensor_info) |ti| {
            if (std.mem.eql(u8, ti.name.str, name)) return ti;
        }
        return null;
    }

    /// Get raw pointer to tensor data region.
    pub fn tensorData(self: *const GGUFFile) [*]const u8 {
        return self.mmap_ptr.ptr + self.tensor_data_offset;
    }

    /// Dump all metadata keys for debugging.
    pub fn dumpMetadata(self: *const GGUFFile, writer: anytype) void {
        for (self.metadata) |kv| {
            const vt: MetadataType = kv.value;
            switch (vt) {
                .string => writer.print("{s} = {s}\n", .{ kv.key.str, kv.value.string.str }) catch {},
                .uint32 => writer.print("{s} = {d}\n", .{ kv.key.str, kv.value.uint32 }) catch {},
                .uint64 => writer.print("{s} = {d}\n", .{ kv.key.str, kv.value.uint64 }) catch {},
                .float32 => writer.print("{s} = {d}\n", .{ kv.key.str, kv.value.float32 }) catch {},
                .array => writer.print("{s} = array[{d}] of {}\n", .{ kv.key.str, kv.value.array.len, kv.value.array.elem_type }) catch {},
                else => writer.print("{s} = ({s})\n", .{ kv.key.str, @tagName(vt) }) catch {},
            }
        }
    }
};

fn getMetadataValue(key: []const u8, metadata: []const MetadataKV) ?Value {
    for (metadata) |kv| {
        if (std.mem.eql(u8, key, kv.key.str)) return kv.value;
    }
    return null;
}
