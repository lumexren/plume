// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 lumexren
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

/// Represent a dbus value
const Value = @This();

pub const DBusWriter = @import("DBusWriter.zig");
pub const Serializer = @import("Serializer.zig");

pub const Wrappers = @import("wrappers/root.zig");
pub const GPath = Wrappers.GPath;
pub const GSig = Wrappers.GSig;
pub const GStr = Wrappers.GStr;
pub const GUFd = Wrappers.GUFd;
pub const ResolvedFd = Wrappers.ResolvedFd;
pub const GVariant = Wrappers.GVariant;
pub const GVariantTag = Wrappers.GVariantTag;

const std = @import("std");
const mem = std.mem;
const math = std.math;

pub fn dbusAlignOf(comptime T: type) usize {
    if (T == GStr or T == GPath) return 4; // 's','o'
    if (T == GSig) return 1; // 'g'
    if (T == GUFd or T == ResolvedFd) return 4; // 'h'
    if (T == GVariant) return 1; // 'v'
    if (comptime Value.isDict(T)) return 4; // 'a'

    return switch (@typeInfo(T)) {
        .int => |info| switch (info.bits) {
            8 => 1,
            16 => 2,
            32 => 4,
            64 => 8,
            else => @compileError("Unsupported integer width for D-Bus"),
        },
        .bool => 4, // 'b' => u32 on wire
        .float => |info| switch (info.bits) {
            64 => 8,
            else => @compileError("Only f64 on D-Bus"),
        },
        .@"struct" => {
            if (@hasDecl(T, "SIGNATURE")) {
                const sig = T.SIGNATURE;
                if (sig.len > 0 and sig[0] == 'a') return 4;
                if (sig.len > 0 and sig[0] == 'v') return 1;
            }
            return 8; // struct/dict-entry container
        },
        .@"union" => 1, // 'v'
        .array => 4, // 'a'
        .pointer => |pi| {
            if (pi.size == .slice) return 4; // 'a'
            if (pi.size == .one) return dbusAlignOf(pi.child);
            @compileError("Unsupported pointer type in dbusAlignOf");
        },
        else => @compileError("Unsupported alignment type for D-Bus " ++ @typeName(T)),
    };
}

pub fn isDict(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .@"struct") {
        if (@hasDecl(T, "KV") and @hasDecl(T, "iterator")) {
            const kv_info = @typeInfo(T.KV);
            if (kv_info == .@"struct" and kv_info.@"struct".field_names.len == 2) {
                const f0 = kv_info.@"struct".field_names[0];
                const f1 = kv_info.@"struct".field_names[1];
                return mem.eql(u8, f0, "key") and mem.eql(u8, f1, "value");
            }
        }
    }
    return false;
}

pub fn dictKV(comptime T: type) struct { key: type, val: type } {
    const fields = @typeInfo(T.KV).@"struct";
    return .{ .key = fields.field_types[0], .val = fields.field_types[1] };
}

fn dictKeyReprLen(comptime K: type) comptime_int {
    if (K == []const u8 or K == [:0]const u8 or K == []u8 or K == [:0]u8) return 1;
    return reprLength(K);
}

pub fn doesImplementSer(comptime T: type) bool {
    if (std.meta.hasMethod(T, "ser")) {
        const Args = std.meta.ArgsTuple(@TypeOf(T.ser));
        const typeInfo = @typeInfo(Args).@"struct";
        return (typeInfo.field_names.len == 2 and typeInfo.field_types[0] == T and typeInfo.field_types[1] == *DBusWriter);
    }

    return false;
}

pub fn reprLength(comptime T: type) comptime_int {
    if (T == void) return 0;
    const info = @typeInfo(T);
    switch (info) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "SIGNATURE")) return @field(T, "SIGNATURE").len;
        },
        else => {},
    }
    if (T == GStr or T == GPath or T == GSig or T == GUFd or T == ResolvedFd or T == GVariant) return 1;
    if (comptime isDict(T)) {
        const kv = dictKV(T);
        return 3 + dictKeyReprLen(kv.key) + reprLength(kv.val);
    }
    switch (info) {
        .int => return 1,
        .bool => return 1,
        .float => |f_info| {
            if (f_info.bits != 64) @compileError("Only f64 supported");
            return 1;
        },
        .@"struct" => |s_info| {
            const is_dict_entry = s_info.field_names.len == 2 and (mem.eql(u8, s_info.field_names[0], "key") and mem.eql(u8, s_info.field_names[1], "value"));
            var len: usize = if (is_dict_entry or !s_info.is_tuple) 2 else 0;
            inline for (s_info.field_names, s_info.field_types) |FieldName, FieldType| {
                if (is_dict_entry and (FieldType == []const u8 or FieldType == [:0]const u8 or FieldType == []u8 or FieldType == [:0]u8) and mem.eql(u8, FieldName, "key")) {
                    len += 1;
                } else {
                    len += reprLength(FieldType);
                }
            }
            return len;
        },
        .@"union" => return 1,
        .array => |a_info| return 1 + reprLength(a_info.child),
        .pointer => |p_info| {
            if (p_info.size == .slice) return 1 + reprLength(p_info.child);
            if (p_info.size == .one) return reprLength(p_info.child);
            @compileError("Unsupported pointer type");
        },
        else => @compileError("Unsupported type for signature " ++ @typeName(T)),
    }
}

pub fn getRepr(comptime T: type, len: comptime_int, start: comptime_int, xs: *[len]u8) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "SIGNATURE")) {
                const S = @field(T, "SIGNATURE");
                @memcpy(xs[start..][0..S.len], S);
                return;
            }
        },
        else => {},
    }
    var real_start: usize = start;

    if (T == GStr) {
        xs[real_start] = 's';
        return;
    } else if (T == GPath) {
        xs[real_start] = 'o';
        return;
    } else if (T == GSig) {
        xs[real_start] = 'g';
        return;
    } else if (T == GUFd or T == ResolvedFd) {
        xs[real_start] = 'h';
        return;
    } else if (T == GVariant) {
        xs[real_start] = 'v';
        return;
    } else if (comptime isDict(T)) {
        const kv = dictKV(T);
        xs[real_start] = 'a';
        xs[real_start + 1] = '{';
        xs[len - 1] = '}';
        const k_len = dictKeyReprLen(kv.key);
        const v_len = reprLength(kv.val);
        if (kv.key == []const u8 or kv.key == [:0]const u8 or kv.key == []u8 or kv.key == [:0]u8) {
            xs[real_start + 2] = 's';
        } else {
            getRepr(kv.key, k_len, 0, @as(*[k_len]u8, @ptrCast(xs[real_start + 2 ..][0..k_len])));
        }
        getRepr(kv.val, v_len, 0, @as(*[v_len]u8, @ptrCast(xs[real_start + 2 + k_len ..][0..v_len])));
        return;
    }

    switch (info) {
        .int => |i_info| {
            xs[real_start] = switch (i_info.bits) {
                8 => 'y',
                16 => if (i_info.signedness == .signed) 'n' else 'q',
                32 => if (i_info.signedness == .signed) 'i' else 'u',
                64 => if (i_info.signedness == .signed) 'x' else 't',
                else => @compileError("Unsupported int"),
            };
        },
        .float => xs[real_start] = 'd',
        .bool => xs[real_start] = 'b',
        .@"struct" => |s_info| {
            const is_dict_entry = s_info.field_names.len == 2 and (mem.eql(u8, s_info.field_names[0], "key") and mem.eql(u8, s_info.field_names[1], "value"));
            if (is_dict_entry) {
                xs[real_start] = '{';
                real_start += 1;
                xs[len - 1] = '}';
            } else if (!s_info.is_tuple) {
                xs[real_start] = '(';
                real_start += 1;
                xs[len - 1] = ')';
            }
            inline for (s_info.field_names, s_info.field_types) |FieldName, FieldType| {
                if (is_dict_entry and (FieldType == []const u8 or FieldType == [:0]const u8 or FieldType == []u8 or FieldType == [:0]u8) and mem.eql(u8, FieldName, "key")) {
                    xs[real_start] = 's';
                    real_start += 1;
                } else {
                    const ll = reprLength(FieldType);
                    getRepr(FieldType, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start..][0..ll])));
                    real_start += ll;
                }
            }
        },
        .array => |a_info| {
            xs[real_start] = 'a';
            const ll = reprLength(a_info.child);
            getRepr(a_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
        },
        .pointer => |p_info| {
            if (p_info.size == .slice) {
                xs[real_start] = 'a';
                const ll = reprLength(p_info.child);
                getRepr(p_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
            } else if (p_info.size == .one) {
                getRepr(p_info.child, len, start, xs);
            } else unreachable;
        },
        .@"union" => xs[real_start] = 'v',
        else => unreachable,
    }
}

/// Array
pub fn Array(comptime T: type) type {
    // NOTE: using [1]T instead of []T because []T is considered to be a pointer value
    const inner_len = reprLength(T);
    const repr_len = 1 + inner_len;
    const rr = blk: {
        var res: [repr_len + 1]u8 = @splat(0);
        res[0] = 'a';
        getRepr(T, inner_len, 0, res[1..repr_len]);
        res[repr_len] = 0;
        break :blk res;
    };

    return struct {
        pub const SIGNATURE: [:0]const u8 = rr[0..repr_len :0];
        inner: []const T,
        repr: []const u8,

        const Self = @This();

        pub fn new(xs: []const T) Self {
            return .{ .inner = xs, .repr = SIGNATURE };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            // 4-align for array container
            try w.padTo(4);

            // Reserve length (u32), patch later
            const len_pos = w.buffer.items.len;
            try w.buffer.appendNTimes(w.allocator, 0, 4);

            // Align element block to element alignment A
            const A = dbusAlignOf(T);
            try w.padTo(A);
            const start_elems = w.buffer.items.len;

            var i: usize = 0;
            while (i < self.inner.len) : (i += 1) {
                // align per element for safety (especially composites)
                try w.padTo(A);
                try Serializer.trySerialize(T, self.inner[i], w);
            }

            // Patch array byte length
            const arr_bytes: usize = w.buffer.items.len - start_elems;
            if (arr_bytes > math.maxInt(u32)) return error.ArrayTooLarge;
            w.writeU32At(len_pos, @intCast(arr_bytes));
        }

        inline fn alignUp(value: usize, alignment: usize) usize {
            return (value + alignment - 1) & ~(alignment - 1);
        }
    };
}

/// Tuple is a set of element. The order of is important
/// `ivv` -> `INT32` `VARIANT` `VARIANT`
pub fn Tuple(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple) @compileError("Tuple() expects a tuple struct");

    const repr_len = reprLength(T);
    var repr_arr: [repr_len]u8 = @splat(0);
    getRepr(T, repr_len, 0, &repr_arr);
    const rr = repr_arr;

    return struct {
        pub const SIGNATURE = &rr;
        inner: T,
        repr: []const u8,

        const Self = @This();

        pub fn new(structure: T) Self {
            return .{ .inner = structure, .repr = &rr };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            inline for (info.@"struct".field_names, info.@"struct".field_types) |FieldName, FieldType| {
                try w.padTo(dbusAlignOf(FieldType));
                try Serializer.trySerialize(FieldType, @field(self.inner, FieldName), w);
            }
        }
    };
}

/// **CONTAINER**
/// Variant type (the type of the value is part of the value itself)
/// Only unions are accepted
pub fn Variant(comptime T: type) type {
    switch (@typeInfo(T)) {
        .@"union" => {
            return struct {
                pub const SIGNATURE = "v";

                inner: T,
                repr: [:0]const u8,

                const Self = @This();

                pub fn new(any: T) Self {
                    return .{ .inner = any, .repr = "v" };
                }

                pub fn ser(self: Self, w: *DBusWriter) anyerror!void {
                    // 1) write signature ('g'), 2) align to inner alignment, 3) write payload
                    switch (self.inner) {
                        inline else => |payload| {
                            const PT = @TypeOf(payload);
                            // signature (1-aligned)
                            try w.writeSignatureOf(PT);
                            // align & write payload
                            try w.padTo(dbusAlignOf(PT));
                            try Serializer.trySerialize(PT, payload, w);
                        },
                    }
                }
            };
        },
        else => @compileError("expected union as variant argument but found " ++ @typeName(T)),
    }
}

/// **CONTAINER**
/// **Struct** type code 114 'r' is reserved for use in bindings and implementations
/// to represent the general concept of a struct, and must not appear in signatures used on D-Bus.
pub fn Struct(comptime S: type) type {
    if (@typeInfo(S) != .@"struct") {
        @compileError("unexpected input type");
    }
    const repr_len = reprLength(S);
    var repr_arr: [repr_len]u8 = @splat(0);
    getRepr(S, repr_len, 0, &repr_arr);
    const rr = repr_arr;

    return struct {
        pub const SIGNATURE = &rr;

        inner: S,
        repr: []const u8,

        const Self = @This();

        pub fn new(structure: S) Self {
            return .{ .inner = structure, .repr = &rr };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            try w.padTo(8);
            const sinfo = @typeInfo(S).@"struct";
            const is_dict_entry = sinfo.field_names.len == 2 and (mem.eql(u8, sinfo.field_names[0], "key") and mem.eql(u8, sinfo.field_names[1], "value"));
            inline for (sinfo.field_names, sinfo.field_types) |FieldName, FieldType| {
                try w.padTo(dbusAlignOf(FieldType));
                if (is_dict_entry and (FieldType == []const u8 or FieldType == [:0]const u8 or FieldType == []u8 or FieldType == [:0]u8) and mem.eql(u8, FieldName, "key")) {
                    try w.padTo(4);
                    const slice = @field(self.inner, FieldName);
                    try w.writeInt(u32, @intCast(slice.len));
                    try w.buffer.appendSlice(w.allocator, slice);
                    try w.buffer.append(w.allocator, 0);
                } else {
                    try Serializer.trySerialize(FieldType, @field(self.inner, FieldName), w);
                }
            }
        }
    };
}

fn BasicType(comptime T: type) type {
    const repr_len = reprLength(T);
    var repr_arr: [repr_len]u8 = @splat(0);
    getRepr(T, repr_len, 0, &repr_arr);
    const rr = repr_arr;

    return struct {
        value: T,
        repr: []const u8,

        const Self = @This();

        pub fn new(value: T) Self {
            return .{ .value = value, .repr = &rr };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            try w.padTo(dbusAlignOf(T));
            switch (@typeInfo(T)) {
                .int => try w.writeInt(T, self.value),
                .float => {
                    const bits: u64 = @bitCast(self.value); // f64
                    try w.writeInt(u64, bits);
                },
                else => unreachable,
            }
        }
    };
}

fn StringLike(r: u8) type {
    const rr = [1]u8{r};
    return struct {
        value: [:0]const u8,
        repr: []const u8,

        const Self = @This();

        pub fn new(value: [:0]const u8) Self {
            return .{ .value = value, .repr = &rr };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            switch (r) {
                's', 'o' => {
                    try w.padTo(4);
                    const len_u32: u32 = @intCast(self.value.len); // not including NUL
                    try w.writeInt(u32, len_u32);
                    try w.buffer.appendSlice(w.allocator, self.value);
                    try w.buffer.append(w.allocator, 0);
                },
                'g' => {
                    try w.padTo(1);
                    const n = self.value.len;
                    if (n > 255) return error.SignatureTooLong;
                    try w.buffer.append(w.allocator, @as(u8, @intCast(n)));
                    try w.buffer.appendSlice(w.allocator, self.value);
                    try w.buffer.append(w.allocator, 0);
                },
                else => unreachable,
            }
        }
    };
}

/// Signed (two's complement) 16-bit integer
pub fn Int16() type {
    return BasicType(i16);
}

/// Unsigned 16-bit integer
pub fn Uint16() type {
    return BasicType(u16);
}

/// Signed (two's complement) 32-bit integer
pub fn Int32() type {
    return BasicType(i32);
}

/// Unsigned 32-bit integer
pub fn Uint32() type {
    return BasicType(u32);
}

/// Signed (two's complement) 64-bit integer (mnemonic: x and t are the first
/// characters in "sixty" not already used for something more common)
pub fn Int64() type {
    return BasicType(i64);
}

/// Unsigned 64-bit integer
pub fn Uint64() type {
    return BasicType(u64);
}

/// IEEE 754 double-precision floating point
pub fn Double() type {
    return BasicType(f64);
}

/// Unsigned 8-bit integer
pub fn Byte() type {
    return BasicType(u8);
}

/// Boolean value: 0 is false, 1 is true, any other value allowed by the marshalling format is invalid
/// It representation in the protocol is a `UINT32`
pub fn Bool() type {
    const repr_len = reprLength(bool);
    var repr_arr: [repr_len]u8 = @splat(0);
    getRepr(bool, repr_len, 0, &repr_arr);
    const rr = repr_arr;

    return struct {
        value: bool,
        repr: []const u8,
        const Self = @This();

        pub fn new(value: bool) Self {
            return Self{
                .value = value,
                .repr = &rr,
            };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            try w.padTo(dbusAlignOf(bool)); // 4
            try w.writeInt(u32, @intFromBool(self.value));
        }
    };
}

/// Unsigned 32-bit integer representing an index into an out-of-band array of
/// file descriptors, transferred via some platform-specific mechanism (mnemonic: h for handle)
pub fn UnixFd() type {
    const rr = [1]u8{'h'};

    return struct {
        handle: u32,
        repr: []const u8,

        const Self = @This();

        pub fn new(handle: u32) Self {
            return .{ .handle = handle, .repr = &rr };
        }

        pub fn ser(self: Self, w: *DBusWriter) !void {
            try w.padTo(4);
            try w.writeInt(u32, self.handle);
        }
    };
}

/// String-like types all end with a single zero (NUL) byte
/// UTF-8 string (must be valid UTF-8)
/// _Validity constraints_: No extra constraints
pub fn String() type {
    return StringLike('s');
}

/// String-like types all end with a single zero (NUL) byte
/// Name of an object instance
/// _Validity constraints_: Must be a [syntactically valid object path](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling-object-path)
pub fn ObjectPath() type {
    return StringLike('o');
}

/// String-like types all end with a single zero (NUL) byte
/// A type signature
/// _Validity constraints_: Zero or more [single complete types](https://dbus.freedesktop.org/doc/dbus-specification.html#term-single-complete-type)
pub fn Signature() type {
    return StringLike('g');
}

test "Signature Generation test" {
    const testing = std.testing;
    const allocator = std.testing.allocator;
    _ = allocator;
    const eql = std.mem.eql;

    const Speed = struct {
        vel: f64,
        acc: u64,
        stopped: bool,
    };

    const Coord = struct {
        x: f64,
        y: f64,
        speed: Speed,
    };

    const TTag = enum { oneValue, twoValue, threeValue };
    const MulTup = union(TTag) {
        oneValue: @Tuple(&[_]type{i32}),
        twoValue: @Tuple(&[_]type{ i32, i32 }),
        threeValue: @Tuple(&[_]type{ i32, i32, i32 }),
    };

    const a = Value.Bool().new(false);
    try testing.expect(eql(u8, a.repr, "b"));

    const xs = Value.Array(i64).new(&[_]i64{ 1, 2, 3 });
    try testing.expect(eql(u8, xs.repr, "ax"));

    const c = Value.Double().new(3.0);
    try testing.expect(eql(u8, c.repr, "d"));

    const coord = Coord{
        .x = 98,
        .y = 199,
        .speed = .{
            .acc = 23,
            .stopped = false,
            .vel = 455,
        },
    };

    const t = Value.Struct(Coord).new(coord);
    try testing.expect(eql(u8, t.repr, "(dd(dtb))"));

    const cx = Value.Array(Coord).new(&[_]Coord{coord});
    try testing.expect(eql(u8, cx.repr, "a(dd(dtb))"));

    const tup = Value.Tuple(@Tuple(&[_]type{ f64, f64, f64 })).new(.{ 4, 4, 4 });
    try testing.expect(eql(u8, tup.repr, "ddd"));

    const va = Value.Variant(MulTup).new(.{ .threeValue = .{ 4, 4, 4 } });
    try testing.expect(eql(u8, va.repr, "v"));

    const MapT = std.StringHashMap(f64);
    const repr_len = Value.reprLength(MapT);
    var repr_buf: [10]u8 = undefined;
    Value.getRepr(MapT, repr_len, 0, repr_buf[0..repr_len]);
    try testing.expect(eql(u8, repr_buf[0..repr_len], "a{sd}"));

    const IntMapT = std.AutoHashMap(u32, Value.GStr);
    const int_repr_len = Value.reprLength(IntMapT);
    var int_repr_buf: [10]u8 = undefined;
    Value.getRepr(IntMapT, int_repr_len, 0, int_repr_buf[0..int_repr_len]);
    try testing.expect(eql(u8, int_repr_buf[0..int_repr_len], "a{us}"));
}

test "ResolvedFd signature and alignment" {
    const testing = std.testing;
    const eql = std.mem.eql;
    try testing.expect(dbusAlignOf(ResolvedFd) == 4);
    try testing.expect(Value.reprLength(ResolvedFd) == 1);
    var repr_buf: [10]u8 = undefined;
    Value.getRepr(ResolvedFd, 1, 0, repr_buf[0..1]);
    try testing.expect(eql(u8, repr_buf[0..1], "h"));

    try testing.expect(dbusAlignOf([]const ResolvedFd) == 4);
    try testing.expect(Value.reprLength([]const ResolvedFd) == 2);
    Value.getRepr([]const ResolvedFd, 2, 0, repr_buf[0..2]);
    try testing.expect(eql(u8, repr_buf[0..2], "ah"));

    try testing.expect(dbusAlignOf([]ResolvedFd) == 4);
    try testing.expect(Value.reprLength([]ResolvedFd) == 2);
    Value.getRepr([]ResolvedFd, 2, 0, repr_buf[0..2]);
    try testing.expect(eql(u8, repr_buf[0..2], "ah"));
}
