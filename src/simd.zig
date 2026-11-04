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
        if (cpu.arch.isPowerPC()) break :D cpu.has(.powerpc, .vsx);
        if (cpu.arch == .s390x) break :D cpu.has(.s390x, .vector);
        // wasm seems to not lower to vector ops, even when relaxed_simd is present
        // if (cpu.arch.isWasm()) break :D cpu.hasAll(.wasm, &.{ .simd128, .relaxed_simd });
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

pub fn length(T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .vector => |v| v.len,
        .array => |a| a.len,
        else => 1,
    };
}

pub fn ScalarOf(T: type) type {
    return switch (@typeInfo(T)) {
        .vector => |v| v.child,
        .array => |a| a.child,
        .pointer => |s| s.child,
        else => T,
    };
}

pub fn last(x: anytype) ScalarOf(@TypeOf(x)) {
    return switch (@typeInfo(@TypeOf(x))) {
        .vector => |v| x[v.len - 1],
        .array, .pointer => x[x.len - 1],
        else => x,
    };
}

pub fn Decay(V: type) type {
    const v = switch (@typeInfo(V)) {
        .vector => |v| v,
        else => @compileError("Expected a vector type"),
    };
    const steps = comptime std.math.log2_int(usize, v.len);
    const Float = v.child;
    return struct {
        const Self = @This();
        linear_fac: [length(V)]Float,
        
        pub fn init(decay: Float) Self {
            var self: Self = undefined;
            var decay_pow: Float = decay;
            inline for (0..self.linear_fac.len) |i| {
                self.linear_fac[i] = decay_pow;
                decay_pow *= decay;
            }
            return self;
        }
        
        pub fn nextVec(self: Self, x: V, y_prev: Float) V {
            var acc = x;
            inline for (0..steps) |iter| {
                const stride = 1 << iter;
                const shifted = std.simd.shiftElementsRight(acc, stride, 0);
                acc = mulAdd(V, shifted, @splat(self.linear_fac[stride - 1]), acc);
            }
            acc = mulAdd(V, self.linear_fac, @splat(y_prev), acc);
            return acc;
        }

        pub fn nextScalar(self: Self, x: Float, y_prev: Float) Float {
            return @mulAdd(Float, self.linear_fac[0], y_prev, x);
        }
    };
}
