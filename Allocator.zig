const builtin = @import("builtin");
const std = @import("std");

const c_alignment_bytes = switch (builtin.target.ptrBitWidth()) {
    64 => 16,
    32 => 8,
    else => unreachable,
};

const MemAlloc2 = fn (usize, u8) callconv(.c) ?*anyopaque;
const MemRealloc2 = fn (?*anyopaque, usize, u8) callconv(.c) ?*anyopaque;
const MemFree2 = fn (?*anyopaque, u8) callconv(.c) void;

var @"fn": struct {
    mem_alloc2: *const MemAlloc2,
    mem_realloc2: *const MemRealloc2,
    mem_free2: *const MemFree2,
} = undefined;

pub fn allocator() std.mem.Allocator {
    const VTable = struct {
        const pad_align = if (builtin.mode == .Debug) 1 else 0;

        inline fn ptrOffsetedPtr(aligned_ptr: ?*anyopaque) *?*anyopaque {
            const aligned_addr = @intFromPtr(aligned_ptr);
            const offseted_addr = aligned_addr -% @sizeOf(?*anyopaque);
            return @ptrFromInt(offseted_addr);
        }

        pub fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const alignment_bytes = alignment.toByteUnits();

            if (alignment_bytes <= c_alignment_bytes) {
                return @ptrCast(@"fn".mem_alloc2(len, pad_align));
            }

            const aligned_len = len + alignment_bytes;
            const raw_ptr = @"fn".mem_alloc2(aligned_len, pad_align) orelse return null;

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
                return @ptrCast(@"fn".mem_realloc2(raw_ptr, new_len, pad_align));
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

            @"fn".mem_free2(raw_ptr, pad_align);
        }
    };

    const vtable = std.mem.Allocator.VTable{
        .alloc = VTable.alloc,
        .resize = VTable.resize,
        .remap = VTable.remap,
        .free = VTable.free,
    };

    return .{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

pub fn init(
    mem_alloc2: *const MemAlloc2,
    mem_realloc2: *const MemRealloc2,
    mem_free2: *const MemFree2,
) void {
    @"fn".mem_alloc2 = mem_alloc2;
    @"fn".mem_realloc2 = mem_realloc2;
    @"fn".mem_free2 = mem_free2;
}

// test

const TestFn = struct {
    var wraper: struct {
        debug_allocator: std.heap.DebugAllocator(.{}),
        allocator: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(?*anyopaque, usize),
    } = undefined;

    pub fn init() void {
        wraper.debug_allocator = .{};
        wraper.allocator = wraper.debug_allocator.allocator();
        wraper.map = .{};
    }

    pub fn deinit() std.heap.Check {
        wraper.map.deinit(wraper.allocator);
        return wraper.debug_allocator.deinit();
    }

    pub fn alloc(bytes: usize, _: u8) callconv(.c) ?*anyopaque {
        const slice = wraper.allocator.alloc(u8, bytes) catch unreachable;
        wraper.map.put(wraper.allocator, slice.ptr, slice.len) catch unreachable;

        return slice.ptr;
    }

    pub fn realloc(ptr: ?*anyopaque, bytes: usize, _: u8) callconv(.c) ?*anyopaque {
        const old_len = wraper.map.fetchRemove(ptr).?.value;
        const old_slice = @as([*]u8, @ptrCast(ptr))[0..old_len];

        const slice = wraper.allocator.realloc(old_slice, bytes) catch unreachable;
        wraper.map.put(wraper.allocator, slice.ptr, slice.len) catch unreachable;

        return slice.ptr;
    }

    pub fn free(ptr: ?*anyopaque, _: u8) callconv(.c) void {
        const len = wraper.map.fetchRemove(ptr).?.value;
        const slice = @as([*]u8, @ptrCast(ptr))[0..len];

        wraper.allocator.free(slice);
    }
};

pub fn initTestFn() void {
    TestFn.init();

    init(
        TestFn.alloc,
        TestFn.realloc,
        TestFn.free,
    );
}

pub fn deinitTestFn() std.heap.Check {
    return TestFn.deinit();
}

test "TestFn check leak" {
    // test empty
    initTestFn();
    try std.testing.expectEqual(deinitTestFn(), .ok);

    // test normal
    initTestFn();

    const p1: [*]u8 = @ptrCast(@"fn".mem_alloc2(8, 0));
    p1[0] = 0;
    p1[7] = 7;
    const p2: [*]u8 = @ptrCast(@"fn".mem_realloc2(p1, 16, 0));
    try std.testing.expectEqual(0, p2[0]);
    try std.testing.expectEqual(7, p2[7]);
    @"fn".mem_free2(p2, 0);

    try std.testing.expectEqual(deinitTestFn(), .ok);
}

test "Allocatr check leak" {
    initTestFn();

    const a = allocator();

    var map = std.AutoArrayHashMap(u64, u64).init(a);

    for (0..1000) |idx| {
        try map.put(idx, idx);
        try map.put(idx, idx);
    }
    map.deinit();

    try std.testing.expectEqual(deinitTestFn(), .ok);
}

test "Allocatr check alignment" {
    initTestFn();

    const a = allocator();

    inline for (0..7) |i| {
        const alignment_bytes = comptime std.math.pow(u64, 2, i);
        const alignment = std.mem.Alignment.fromByteUnits(alignment_bytes);

        const T = struct { a: [alignment_bytes]u8 align(alignment_bytes) };

        const ptr = try a.create(T);
        const addr = @intFromPtr(ptr);

        try std.testing.expect(alignment.check(addr));

        a.destroy(ptr);
    }

    try std.testing.expectEqual(deinitTestFn(), .ok);
}
