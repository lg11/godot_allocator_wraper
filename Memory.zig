const builtin = @import("builtin");
const std = @import("std");

const wraper = struct {
    pub const Bool = enum(u8) { true = 1, false = 0 };

    const c_alignment_bytes = switch (builtin.target.ptrBitWidth()) {
        64 => 16,
        32 => 8,
        else => unreachable,
    };
    const pad_align: Bool = if (builtin.mode == .Debug) .true else .false;

    const MemAlloc2 = fn (usize, Bool) callconv(.c) ?*anyopaque;
    const MemRealloc2 = fn (?*anyopaque, usize, Bool) callconv(.c) ?*anyopaque;
    const MemFree2 = fn (?*anyopaque, Bool) callconv(.c) void;

    var mem_alloc2: *const MemAlloc2 = undefined;
    var mem_realloc2: *const MemRealloc2 = undefined;
    var mem_free2: *const MemFree2 = undefined;

    inline fn ptrOffsetedPtr(aligned_ptr: ?*anyopaque) *?*anyopaque {
        const aligned_addr = @intFromPtr(aligned_ptr);
        const offseted_addr = aligned_addr -% @sizeOf(?*anyopaque);
        return @ptrFromInt(offseted_addr);
    }

    pub fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const alignment_bytes = alignment.toByteUnits();

        if (alignment_bytes <= c_alignment_bytes) {
            return @ptrCast(mem_alloc2(len, pad_align));
        }

        const aligned_len = len + alignment_bytes;
        const raw_ptr = mem_alloc2(aligned_len, pad_align) orelse return null;

        const raw_addr = @intFromPtr(raw_ptr);
        const aligned_addr = raw_addr + (alignment_bytes - raw_addr % alignment_bytes);
        const aligned_ptr: ?*anyopaque = @ptrFromInt(aligned_addr);

        ptrOffsetedPtr(aligned_ptr).* = raw_ptr;

        return @ptrCast(aligned_ptr);
    }

    pub fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    pub fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        const alignment_bytes = alignment.toByteUnits();

        if (alignment_bytes <= c_alignment_bytes) {
            const raw_ptr: ?*anyopaque = @ptrCast(memory.ptr);
            return @ptrCast(mem_realloc2(raw_ptr, new_len, pad_align));
        }

        return null;
    }

    pub fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
        const alignment_bytes = alignment.toByteUnits();

        const aligned_ptr: ?*anyopaque = @ptrCast(memory.ptr);
        const raw_ptr = switch (alignment_bytes <= c_alignment_bytes) {
            true => aligned_ptr,
            false => ptrOffsetedPtr(aligned_ptr).*,
        };

        mem_free2(raw_ptr, pad_align);
    }
};

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = wraper.alloc,
        .resize = wraper.resize,
        .remap = wraper.remap,
        .free = wraper.free,
    },
};

pub fn init(
    mem_alloc2: *const wraper.MemAlloc2,
    mem_realloc2: *const wraper.MemRealloc2,
    mem_free2: *const wraper.MemFree2,
) void {
    wraper.mem_alloc2 = mem_alloc2;
    wraper.mem_realloc2 = mem_realloc2;
    wraper.mem_free2 = mem_free2;
}

// test

const test_wraper = struct {
    var internal: struct {
        debug_allocator: std.heap.DebugAllocator(.{}),
        allocator: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(?*anyopaque, usize),
    } = undefined;

    pub fn init() void {
        internal.debug_allocator = .{};
        internal.allocator = internal.debug_allocator.allocator();
        internal.map = .{};
    }

    pub fn deinit() std.heap.Check {
        internal.map.deinit(internal.allocator);
        return internal.debug_allocator.deinit();
    }

    pub fn alloc(bytes: usize, _: wraper.Bool) callconv(.c) ?*anyopaque {
        const slice = internal.allocator.alloc(u8, bytes) catch unreachable;
        internal.map.put(internal.allocator, slice.ptr, slice.len) catch unreachable;

        return slice.ptr;
    }

    pub fn realloc(ptr: ?*anyopaque, bytes: usize, _: wraper.Bool) callconv(.c) ?*anyopaque {
        const old_len = internal.map.fetchRemove(ptr).?.value;
        const old_slice = @as([*]u8, @ptrCast(ptr))[0..old_len];

        const slice = internal.allocator.realloc(old_slice, bytes) catch unreachable;
        internal.map.put(internal.allocator, slice.ptr, slice.len) catch unreachable;

        return slice.ptr;
    }

    pub fn free(ptr: ?*anyopaque, _: wraper.Bool) callconv(.c) void {
        const len = internal.map.fetchRemove(ptr).?.value;
        const slice = @as([*]u8, @ptrCast(ptr))[0..len];

        internal.allocator.free(slice);
    }
};

pub fn initTest() void {
    test_wraper.init();

    init(
        test_wraper.alloc,
        test_wraper.realloc,
        test_wraper.free,
    );
}

pub fn deinitTest() std.heap.Check {
    return test_wraper.deinit();
}

test "TestFn check leak" {
    // test empty
    initTest();
    try std.testing.expectEqual(deinitTest(), .ok);

    // test normal
    initTest();

    const p1: [*]u8 = @ptrCast(wraper.mem_alloc2(8, .false));
    p1[0] = 0;
    p1[7] = 7;
    const p2: [*]u8 = @ptrCast(wraper.mem_realloc2(p1, 16, .false));
    try std.testing.expectEqual(0, p2[0]);
    try std.testing.expectEqual(7, p2[7]);
    wraper.mem_free2(p2, .false);

    try std.testing.expectEqual(deinitTest(), .ok);
}

test "Allocatr check leak" {
    initTest();

    var map = std.AutoArrayHashMap(u64, u64).init(allocator);

    for (0..1000) |idx| {
        try map.put(idx, idx);
        try map.put(idx, idx);
    }
    map.deinit();

    try std.testing.expectEqual(deinitTest(), .ok);
}

test "Allocatr check alignment" {
    initTest();

    inline for (0..7) |i| {
        const alignment_bytes = comptime std.math.pow(u64, 2, i);
        const alignment = std.mem.Alignment.fromByteUnits(alignment_bytes);

        const T = struct { a: [alignment_bytes]u8 align(alignment_bytes) };

        const ptr = try allocator.create(T);
        const addr = @intFromPtr(ptr);

        try std.testing.expect(alignment.check(addr));

        allocator.destroy(ptr);
    }

    try std.testing.expectEqual(deinitTest(), .ok);
}
