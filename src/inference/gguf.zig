// GGUF file format parser
// Adapted from camconn/llm.zig (AGPL-3.0) and ggml-org/ggml
//
// Parses GGUF v3 files: header, metadata KV pairs, tensor info, mmap'd tensor data.

const std = @import("std");

const page_size = std.heap.page_size_min;
const Reader = std.io.FixedBufferStream([]align(page_size) u8).Reader;

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

pub const String = struct {
    len: u64,
    str: []u8,

    fn read(reader: Reader, alloc: std.mem.Allocator) Error!String {
        const len = reader.readInt(u64, .little) catch return Error.EOF;
        const buf = alloc.alloc(u8, len) catch return Error.Alloc;
        const n_read = reader.read(buf) catch return Error.FileError;
        if (n_read != len) return Error.FileError;
        return .{ .len = len, .str = buf };
    }
};

pub const Array = struct {
    elem_type: MetadataType,
    len: u64,
    array: []Value,

    fn read(reader: Reader, alloc: std.mem.Allocator) Error!Array {
        const element_type = reader.readEnum(MetadataType, .little) catch return Error.EOF;
        const len = reader.readInt(u64, .little) catch return Error.EOF;

        var list: std.ArrayList(Value) = .{};
        for (0..len) |_| {
            const val = try Value.read(element_type, reader, alloc);
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

    fn read(value_type: MetadataType, reader: Reader, alloc: std.mem.Allocator) Error!Value {
        // zig fmt: off
        return switch (value_type) {
            .uint8   => .{ .uint8   = reader.readInt(u8, .little)  catch return Error.EOF },
            .int8    => .{ .int8    = reader.readInt(i8, .little)  catch return Error.EOF },
            .uint16  => .{ .uint16  = reader.readInt(u16, .little) catch return Error.EOF },
            .int16   => .{ .int16   = reader.readInt(i16, .little) catch return Error.EOF },
            .uint32  => .{ .uint32  = reader.readInt(u32, .little) catch return Error.EOF },
            .int32   => .{ .int32   = reader.readInt(i32, .little) catch return Error.EOF },
            .uint64  => .{ .uint64  = reader.readInt(u64, .little) catch return Error.EOF },
            .int64   => .{ .int64   = reader.readInt(i64, .little) catch return Error.EOF },
            .boolean => .{ .boolean = (reader.readInt(u8, .little) catch return Error.EOF) == 1 },
            .float32 => .{ .float32 = @bitCast(reader.readInt(u32, .little) catch return Error.EOF) },
            .float64 => .{ .float64 = @bitCast(reader.readInt(u64, .little) catch return Error.EOF) },
            .string  => .{ .string  = try String.read(reader, alloc) },
            .array   => .{ .array   = try Array.read(reader, alloc) },
        };
        // zig fmt: on
    }
};

pub const MetadataKV = struct {
    key: String,
    value: Value,

    fn read(reader: Reader, alloc: std.mem.Allocator) Error!MetadataKV {
        const key = try String.read(reader, alloc);
        const value_type = reader.readEnum(MetadataType, .little) catch return Error.EOF;
        const value = try Value.read(value_type, reader, alloc);
        return .{ .key = key, .value = value };
    }
};

pub const GGUFHeader = struct {
    const magic_str = "GGUF";
    const magic_num = std.mem.readInt(u32, magic_str, .little);

    version: u32,
    tensor_count: u64,
    metadata_kv_count: u64,

    pub fn read(reader: Reader) Error!GGUFHeader {
        const magic = reader.readInt(u32, .little) catch return Error.EOF;
        if (magic != magic_num) return Error.Format;
        const version = reader.readInt(u32, .little) catch return Error.EOF;
        if (version != 3) return Error.Format;
        const tensor_count = reader.readInt(u64, .little) catch return Error.EOF;
        const metadata_kv_count = reader.readInt(u64, .little) catch return Error.EOF;
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
        const dim = reader.readInt(u32, .little) catch return Error.EOF;
        std.debug.assert(dim > 0);
        const dimensions = alloc.alloc(u64, dim) catch return Error.Alloc;
        for (0..dim) |i| {
            dimensions[i] = reader.readInt(u64, .little) catch return Error.EOF;
        }
        const ggml_type = reader.readEnum(Type, .little) catch return Error.EOF;
        const offset: usize = @intCast(reader.readInt(u64, .little) catch return Error.EOF);

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
    pub fn numElements(self: TensorInfo) usize {
        var len: usize = 1;
        for (self.dimensions) |d| len *= @intCast(d);
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
    fd: std.posix.fd_t,
    mmap_ptr: []align(page_size) u8,
    file_size: usize,

    pub fn open(path: []const u8, alloc: std.mem.Allocator) !GGUFFile {
        // Open and mmap the file
        const fd = std.posix.open(path, .{}, 0o440) catch return Error.FileError;
        errdefer std.posix.close(fd);

        const stat = std.posix.fstat(fd) catch return Error.FileError;
        const fsize: u64 = @intCast(stat.size);

        const mmap_type: std.posix.MAP = .{
            .TYPE = .SHARED,
            .NORESERVE = true,
            .POPULATE = true,
        };
        const ptr = std.posix.mmap(null, fsize, std.posix.PROT.READ, mmap_type, fd, 0) catch return Error.FileError;
        errdefer std.posix.munmap(ptr);

        const madvise_flags = std.posix.MADV.SEQUENTIAL | std.posix.MADV.WILLNEED;
        std.posix.madvise(ptr.ptr, fsize, madvise_flags) catch {};

        // Parse header and metadata
        var stream = std.io.fixedBufferStream(ptr);
        const reader = stream.reader();

        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();

        const header = try GGUFHeader.read(reader);

        // Read metadata
        var meta_list: std.ArrayList(MetadataKV) = .{};
        for (0..header.metadata_kv_count) |_| {
            const kv = try MetadataKV.read(reader, a);
            meta_list.append(a, kv) catch return Error.Alloc;
        }
        const metadata = meta_list.toOwnedSlice(a) catch return Error.Alloc;

        // Get alignment
        const alignment: usize = blk: {
            if (getMetadataValue("general.alignment", metadata)) |val| {
                if (val == .uint32) break :blk val.uint32;
            }
            break :blk 32;
        };

        // Read tensor info
        var tensor_list: std.ArrayList(TensorInfo) = .{};
        for (0..header.tensor_count) |_| {
            const ti = try TensorInfo.read(reader, alignment, a);
            tensor_list.append(a, ti) catch return Error.Alloc;
        }
        const tensor_info = tensor_list.toOwnedSlice(a) catch return Error.Alloc;

        // Calculate tensor data offset (aligned)
        const file_offset: usize = @intCast(stream.pos);
        const tensor_data_offset = std.mem.alignForward(usize, file_offset, alignment);

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
            std.posix.munmap(self.mmap_ptr);
            std.posix.close(self.fd);
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
