最近在研究怎么用zig写godot的扩展。

第一个目标是把godot的内存分配器（mem_alloc2/mem_realloc2/mem_free2）包装成zig的`std.mem.Allocator`，让godot可以监控扩展的内存使用情况，用起来也更方便。

`std.mem.Allocator`的结构很简单：

```zig
pub const Allocator = struct {
	ptr: *anyopaque,
	vtable: *const VTable
};
```

`VTable`结构体内则是四个函数指针：

```zig
pub const VTable = struct {
	alloc: *const fn (*anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8,
	resize: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool,
	remap: *const fn (*anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8,
	free: *const fn (*anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void,
```

`alignment`参数是c系语言里没有的，zig的分配器可以更精确地控制内存对齐。

这方面的知识我也是现学的，简单的说，现代64位系统上的c标准库，可以保证分配的指针都是16位对齐的，但是如果有更高位数的对齐需要（调用avx指令做向量计算会有这样的需求），c标准库是不做保证的。

虽然我觉得应该不会用到16位以上的对齐，但本着来都来了的精神，之后还是会处理这个对齐需求的。

另外一个`ret_addr`则是给zig的调试器使用的，这我就直接忽略了。

然后对应的，也去看下godot那边的api：

```c
typedef void *(*GDExtensionInterfaceMemAlloc2)(size_t p_bytes, GDExtensionBool p_pad_align);
typedef void *(*GDExtensionInterfaceMemRealloc2)(void *p_ptr, size_t p_bytes, GDExtensionBool p_pad_align);
typedef void (*GDExtensionInterfaceMemFree2)(void *p_ptr, GDExtensionBool p_pad_align);
```

和c标准库相比，三个函数都多了一个`p_pad_align`参数（`GDExtensionBool`实际上是`uint8_t`），这个参数控制分配器是否会在分配的内存前增加一块至少8字节的元数据区，用来做内存分析。

去看了一下godot的源代码（`core/os/memory.cpp`），实际上是多分配了16字节，前8个字节保存了返回给调用者的指针地址（虽然源代码里管这段的offset叫`SIZE_OFFSET`，但实际保存的确实是地址），后8个字节则是元数据。

然后源代码里还有这么段：

```c++
template <bool p_ensure_zero>
void *Memory::alloc_static(size_t p_bytes, bool p_pad_align) {
#ifdef DEBUG_ENABLED
	bool prepad = true;
#else
	bool prepad = p_pad_align;
#endif

...
```

那么在DEBUG构建中，哪怕调用者设置了`p_pad_align = 0`，godot仍然会多分配16字节。不过这个应该只影响godot自身。一般用的是RELEASE构建的godot的，所以按我的理解，还是是DEBUG传`0`、RELEASE 传`1`就可以了。

另外，模板参数`p_ensure_zero`可以忽略，给扩展提供的接口已经特化为`false`了。

两边的接口都看过以后，就可以去实现包装函数了。

先是`alloc`：

```zig
const builtin = @import("builtin");

const c_alignment_bytes = switch (builtin.target.ptrBitWidth()) {
    64 => 16,
    32 => 8,
    else => unreachable,
};

...

const pad_align = if (builtin.mode == .Debug) 1 else 0;

const VTable = struct {
    inline fn offseted_ptr_ptr(aligned_ptr: ?*anyopaque) *?*anyopaque {
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

	    offseted_ptr_ptr(aligned_ptr).* = raw_ptr;

	    return @ptrCast(aligned_ptr);
	}

	...
```

这里可以看到，为了支持`alignment`参数，所以做了处理，对于超出c标准库保证的对齐需求，手工对齐内存，然后向前偏移一个指针长度，用来保存底层分配器返回的原始指针，然后把对齐后的地址返回给调用者。

之后是`resize`函数：

```zig
const VTable = struct {
	...
	
	pub fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    
    ...
```

简单粗暴地返回`false`，因为`resize`要求不改变指针的地址，godot提供的接口不能提供这种保证，所以返回`false`，告知调用者无法提供这个功能。原文档是：

```
resize which returns false when the Allocator implementation cannot change the size without relocating the allocation.
```


然后是`remap`函数。这个函数比较特殊，它的要求是，如果不能提供比手工复制内存更高的效率，应该返回`null`，原文档是：

```
remap which returns null when the Allocator implementation cannot do the realloc more efficiently than the caller
```

这个我琢磨了一阵才理解。简单地说，如果你的`remap`返回`null`，那么上层的`std.mem.Allocator`实现会调用你提供的`alloc`去申请新内存，然后`@memcpy`复制内容，最后调用你提供的`free`释放旧内存（具体代码见`std.mem.Allocator.reallocAdvanced`）。

如果你的`remap`函数没法提供比这个操作更高的性能，那就应该返回`null`。

那么对我来说，需要处理手工对齐的时候就也需要走这个流程，所以那时就应该返回`null`。最后函数实现如下：

```zig
const VTable = struct {
	...
	
    pub fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
		const alignment_bytes = alignment.toByteUnits();

		if (alignment_bytes <= c_alignment_bytes) {
			const raw_ptr: ?*anyopaque = @ptrCast(memory.ptr);
			return @ptrCast(mem_realloc2(raw_ptr, new_len, pad_align));
		}

		return null;
	}

    ...
```

最后就是`free`了：

```zig
const VTable = struct {
	...
	
	pub fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
		const alignment_bytes = alignment.toByteUnits();

		const aligned_ptr: ?*anyopaque = @ptrCast(memory.ptr);
		const raw_ptr = switch (alignment_bytes <= c_alignment_bytes) {
			true => aligned_ptr,
			false => offseted_ptr_ptr(aligned_ptr).*,
		};

		@"fn".mem_free2(raw_ptr, pad_align);
	}

    ...
```

逻辑也很简单，对于手工对齐过的指针，通过`offseted_ptr_ptr`反查原始地址来进行释放。

最后还写一个反向的包装，把`std.heap.DebugAllocator`包装成`mem_alloc2`/`mem_realloc2`/`mem_free2`用来进行测试。这个就不详细展开说明了，参看完整的源代码（[github链接](https://github.com/lg11/godot_allocator_wraper)）即可。
