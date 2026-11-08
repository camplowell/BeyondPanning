//! A WebAssembly worklet to preview the Blockhead subsystem in isolation
const std = @import("std");
const Blockhead = @import("Blockhead");

const block_len = 128;

var input: [block_len]f32 = @splat(0);
var output: [2][block_len]f32 = @splat(@splat(0));

var head: Blockhead = .init(48000, 0.076, 0.009);

export fn configureListener(sample_rate: f32, radius: f32, block: f32) void {
    head = .init(sample_rate, radius, block);
}

export fn inPtr() u32 {
    return @intCast(@intFromPtr(&input));
}

export fn outPtr() u32 {
    return @intCast(@intFromPtr(&output));
}

export fn initSource(x: f32, y: f32, z: f32) u32 {
    const ret = std.heap.wasm_allocator.create(Blockhead.Filter) catch return 0;
    ret.* = Blockhead.Filter.init(std.heap.wasm_allocator, block_len, head, .{x, y, z}) catch return 0;
    return @intCast(@intFromPtr(ret));
}

export fn deinitSource(ptr: u32) void {
    const src: *Blockhead.Filter = @ptrFromInt(ptr);
    src.deinit(std.heap.wasm_allocator);
    std.heap.wasm_allocator.destroy(src);
}

export fn setDirection(ptr: u32, x: f32, y: f32, z: f32) void {
    const src: *Blockhead.Filter = @ptrFromInt(ptr);
    src.target = .init(head, .{ x, y, z });
}

export fn process(ptr: u32) void {
    const src: *Blockhead.Filter = @ptrFromInt(ptr);
    src.process(&input, &.{&output[0], &output[1]});
}
