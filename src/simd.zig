const builtin = @import("builtin");
const std = @import("std");
pub const len = std.simd.suggestVectorLength(f32) orelse 4;

pub const Vec: type = @Vector(len, f32);
pub const UVec: type = @Vector(len, u32);

pub fn splat(T: type, val: anytype) T {
    switch (@typeInfo(T)) {
        .array => |t| return switch (@typeInfo(@TypeOf(val))) {
            .array, .vector => val,
            else => @splat(@as(t.child, val)),
        },
        .vector => |t| return switch (@typeInfo(@TypeOf(val))) {
            .array, .vector => val,
            else => @splat(@as(t.child, val)),
        },
        else => return val,
    }
}

/// Similar to @mulAdd, but doesn't lower all the way to scalar operations if the cpu
/// doesn't support fma for vectors.
pub fn mulAdd(T: type, a: T, b: T, c: T) T {
    const cpu = builtin.target.cpu;
    const supports_vector_fma = D: {
        if (cpu.arch.isX86()) break :D cpu.has(.x86, .fma);
        if (cpu.arch.isAarch64()) break :D cpu.has(.aarch64, .neon);
        if (cpu.arch.isRiscv()) break :D cpu.has(.arm, .neon) and cpu.has(.arm, .vfp4);
        if (cpu.arch.isWasm()) break :D cpu.hasAll(.wasm, &.{ .simd128, .relaxed_simd });
        if (cpu.arch.isPowerPC()) break :D cpu.has(.powerpc, .vsx);
        if (cpu.arch == .s390x) break :D cpu.has(.s390x, .vector);
        break :D false;
    };
    return switch (@typeInfo(T)) {
        .vector => if (supports_vector_fma)
            @mulAdd(T, a, b, c) else 
            splat(T, a) * splat(T, b) + splat(T, c),
        .array => |info| D: {
            const VecT = @Vector(info.len, info.child);
            break :D if (supports_vector_fma) 
                @mulAdd(VecT, a, b, c) else 
                splat(VecT, a) * splat(VecT, b) + splat(VecT, c);
        },
        else => @mulAdd(T, a, b, c),
    };
}

pub fn iota(T: type) T {
    switch (@typeInfo(T)) {
        .vector => |v| return std.simd.iota(v.child, v.len),
        .array => |a| return std.simd.iota(a.child, a.len),
        .float, .int => return 0,
        else => @compileError("Unsupported target for iota")
    }
}
