const std = @import("std");
pub const len = std.simd.suggestVectorLength(f32) orelse 4;

pub const Vec: type = @Vector(len, f32);
pub const UVec: type = @Vector(len, u32);

pub fn splat(T: type, val: anytype) T {
    switch (@typeInfo(T)) {
        .array => |t| return switch(@typeInfo(@TypeOf(val))) {
            .array, .vector => val,
            else => @splat(@as(t.child, val)),
        },
        .vector => |t| return switch(@typeInfo(@TypeOf(val))) {
            .array, .vector => val,
            else => @splat(@as(t.child, val)),
        },
        else => return val,
    }
}
