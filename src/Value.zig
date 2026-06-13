// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erffy
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

const Serializer = @import("Serializer.zig");
const DBusWriter = @import("DBusWriter.zig");

const std = @import("std");
const meta = std.meta;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;

/// Returns the D-Bus alignment requirement for a type.
pub fn dbusAlignOf(comptime T: type) usize {
    if (T == GStr or T == GPath) return 4; // 's','o'
    if (T == GSig) return 1; // 'g'
    if (T == GUFd) return 4; // 'h'

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
        .pointer => 4, // 'a' (slice is encoded as array)
        else => @compileError("Unsupported alignment type for D-Bus"),
    };
}

/// A wrapper for D-Bus string values.
pub const GStr = struct {
    s: [:0]const u8,
    /// Creates a new GStr from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus object path values.
pub const GPath = struct {
    s: [:0]const u8,
    /// Creates a new GPath from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus signature values.
pub const GSig = struct {
    s: [:0]const u8,
    /// Creates a new GSig from a null-terminated string.
    pub fn new(s: [:0]const u8) @This() {
        return .{ .s = s };
    }
};

/// A wrapper for D-Bus Unix file descriptor values.
pub const GUFd = struct {
    fd: u32,
    /// Creates a new GUFd from a file descriptor.
    pub fn new(fd: u32) @This() {
        return .{ .fd = fd };
    }
};

/// Checks whether a type implements the D-Bus serialization interface (.ser method).
pub fn doesImplementSer(comptime T: type) bool {
    if (meta.hasMethod(T, "ser")) {
        const Args = meta.ArgsTuple(@TypeOf(T.ser));
        const fx = meta.fieldTypes(Args);
        return (fx.len == 2 and fx[0] == T and fx[1] == *DBusWriter);
    }

    return false;
}

/// Returns the length of the D-Bus type signature for a given type.
pub fn reprLength(comptime T: type) comptime_int {
    if (T == void) return 0;
    const info = @typeInfo(T);
    switch (info) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "SIGNATURE")) {
                return @field(T, "SIGNATURE").len;
            }
        },
        else => {},
    }

    if (T == GStr or T == GPath or T == GSig or T == GUFd) return 1;

    switch (info) {
        .int => return 1,
        .bool => return 1,
        .float => |f_info| {
            if (f_info.bits != 64) @compileError("Only f64 supported");
            return 1;
        },
        .@"struct" => |s_info| {
            var len: usize = if (s_info.field_types.len == 2 and (mem.eql(u8, s_info.field_names[0], "key") and mem.eql(u8, s_info.field_names[1], "value")) or !s_info.is_tuple) 2 else 0;
            inline for (s_info.field_types) |field| len += reprLength(field);
            return len;
        },
        .@"union" => return 1,
        .array => |a_info| return 1 + reprLength(a_info.child),
        .pointer => |p_info| {
            if (p_info.size == .slice) return 1 + reprLength(p_info.child);
            @compileError("Unsupported pointer type");
        },
        else => @compileError("Unsupported type for signature"),
    }
}

/// Writes the D-Bus type signature representation into the provided buffer.
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
    } else if (T == GUFd) {
        xs[real_start] = 'h';
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
            const is_dict_entry = s_info.field_types.len == 2 and (mem.eql(u8, s_info.field_names[0], "key") and mem.eql(u8, s_info.field_names[1], "value"));
            if (is_dict_entry) {
                xs[real_start] = '{';
                real_start += 1;
                xs[len - 1] = '}';
            } else if (!s_info.is_tuple) {
                xs[real_start] = '(';
                real_start += 1;
                xs[len - 1] = ')';
            }
            inline for (s_info.field_types) |field| {
                const ll = reprLength(field);
                getRepr(field, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start..][0..ll])));
                real_start += ll;
            }
        },
        .array => |a_info| {
            xs[real_start] = 'a';
            const ll = reprLength(a_info.child);
            getRepr(a_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
        },
        .pointer => |p_info| {
            xs[real_start] = 'a';
            const ll = reprLength(p_info.child);
            getRepr(p_info.child, ll, 0, @as(*[ll]u8, @ptrCast(xs[real_start + 1 ..][0..ll])));
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
        getRepr(T, inner_len, 0, @as(*[inner_len]u8, @ptrCast(res[1..repr_len].ptr)));
        res[repr_len] = 0;
        break :blk res;
    };

    return struct {
        pub const SIGNATURE: [:0]const u8 = rr[0..repr_len :0];
        inner: []const T,
        repr: []const u8,

        pub fn new(xs: []const T) @This() {
            return .{
                .inner = xs,
                .repr = &rr,
            };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
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
            while (i < this.inner.len) : (i += 1) {
                // align per element for safety (especially composites)
                try w.padTo(A);
                try Serializer.trySerialize(T, this.inner[i], w);
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

        pub fn new(structure: T) @This() {
            return .{ .inner = structure, .repr = &rr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            inline for (info.@"struct".fields) |fld| {
                try w.padTo(dbusAlignOf(fld.type));
                try Serializer.trySerialize(fld.type, @field(this.inner, fld.name), w);
            }
        }
    };
}

/// **CONTAINER**
/// Entry in a dict or map (array of key-value pairs). Type code 101 'e' is
/// reserved for use in bindings and implementations to represent the general
/// concept of a dict or dict-entry, and must not appear in signatures used on D-Bus.
pub fn Dict(comptime K: type, comptime V: type, comptime M: type) type {
    const key_repr_len = reprLength(K);
    const value_repr_len = reprLength(V);

    const total_len = value_repr_len + key_repr_len + 3;
    const repr_arr = blk: {
        var rr: [total_len + 1]u8 = @splat(0);
        rr[0] = 'a';
        rr[1] = '{';
        rr[total_len - 1] = '}';
        rr[total_len] = 0;
        getRepr(K, key_repr_len, 0, @as(*[key_repr_len]u8, @ptrCast(rr[2 .. key_repr_len + 2].ptr)));
        getRepr(V, value_repr_len, 0, @as(*[value_repr_len]u8, @ptrCast(rr[key_repr_len + 2 .. (total_len - 1)].ptr)));
        break :blk rr;
    };

    return struct {
        pub const SIGNATURE: [:0]const u8 = repr_arr[0..total_len :0];
        inner: M,
        repr: []const u8,

        pub fn init(allocator: Allocator) @This() {
            return .{ .repr = &repr_arr, .inner = M.init(allocator) };
        }

        pub fn new(inner: M) @This() {
            return .{ .repr = &repr_arr, .inner = inner };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            // This is precisely: Array of dict-entry
            // Array header (4-align)
            try w.padTo(4);
            const len_pos = w.buffer.items.len;
            try w.buffer.appendNTimes(w.allocator, 0, 4);

            // Elements block must start at 8 (dict-entry alignment)
            try w.padTo(8);
            const start_elems = w.buffer.items.len;

            // Iterate entries (supports std.StringHashMap and slices of {key,value})
            if (meta.hasMethod(@TypeOf(this.inner), "iterator")) {
                var it = this.inner.iterator();
                while (it.next()) |e| {
                    try w.padTo(8); // each dict-entry
                    try w.padTo(dbusAlignOf(K));
                    const key = e.key_ptr.*;
                    if (comptime K == GStr) {
                        try w.padTo(4);
                        try w.writeInt(u32, @intCast(key.len));
                        try w.buffer.appendSlice(w.allocator, key);
                        try w.buffer.append(w.allocator, 0);
                    } else {
                        try Serializer.trySerialize(K, key, w);
                    }

                    try w.padTo(dbusAlignOf(V));
                    try Serializer.trySerialize(V, e.value_ptr.*, w);
                }
            } else switch (@typeInfo(@TypeOf(this.inner))) {
                .pointer => |pi| {
                    if (pi.size != .slice) return error.UnsupportedDictBacking;
                    const Elem = pi.child;
                    const einfo = @typeInfo(Elem);
                    if (einfo != .@"struct") return error.UnsupportedDictBacking;
                    inline for (einfo.@"struct".fields) |_| {} // keep einfo constexpr
                    for (this.inner) |ev| {
                        try w.padTo(8);
                        const k = @field(ev, "key");
                        const v = @field(ev, "value");
                        try w.padTo(dbusAlignOf(K));
                        if (comptime K == GStr) {
                            try w.padTo(4);
                            try w.writeInt(u32, @intCast(k.s.len));
                            try w.buffer.appendSlice(w.allocator, k.s);
                            try w.buffer.append(w.allocator, 0);
                        } else {
                            try Serializer.trySerialize(K, k, w);
                        }
                        try w.padTo(dbusAlignOf(V));
                        try Serializer.trySerialize(V, v, w);
                    }
                },
                else => return error.UnsupportedDictBacking,
            }

            // Patch array byte length
            const arr_bytes: usize = w.buffer.items.len - start_elems;
            if (arr_bytes > math.maxInt(u32)) return error.ArrayTooLarge;
            w.writeU32At(len_pos, @intCast(arr_bytes));
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

                pub fn new(any: T) @This() {
                    return .{ .inner = any, .repr = "v" };
                }

                pub fn ser(this: @This(), w: *DBusWriter) anyerror!void {
                    // 1) write signature ('g'), 2) align to inner alignment, 3) write payload
                    switch (this.inner) {
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

        pub fn new(structure: S) @This() {
            return .{ .inner = structure, .repr = &rr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            try w.padTo(8);
            inline for (@typeInfo(S).@"struct".field_types, @typeInfo(S).@"struct".field_names) |field, name| {
                try w.padTo(dbusAlignOf(field));
                try Serializer.trySerialize(field, @field(this.inner, name), w);
            }
        }
    };
}

/// Creates a basic numeric or boolean D-Bus value wrapper (internal helper).
fn BasicType(comptime T: type) type {
    const repr_len = reprLength(T);
    var repr_arr: [repr_len]u8 = @splat(0);
    getRepr(T, repr_len, 0, &repr_arr);
    const rr = repr_arr;
    return struct {
        value: T,
        repr: []const u8,

        pub fn new(value: T) @This() {
            return .{ .value = value, .repr = &rr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            try w.padTo(dbusAlignOf(T));
            switch (@typeInfo(T)) {
                .int => try w.writeInt(T, this.value),
                .float => {
                    const bits: u64 = @bitCast(this.value); // f64
                    try w.writeInt(u64, bits);
                },
                else => unreachable,
            }
        }
    };
}

/// Creates a string-like D-Bus value wrapper for a given type code (internal helper).
fn StringLike(r: u8) type {
    const repr_len = 1;
    return struct {
        value: [:0]const u8,
        repr: []const u8,

        pub fn new(value: [:0]const u8) @This() {
            var repr_arr: [repr_len]u8 = @splat(0);
            repr_arr[0] = r;
            return .{ .value = value, .repr = &repr_arr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            switch (r) {
                's', 'o' => {
                    try w.padTo(4);
                    const len_u32: u32 = @intCast(this.value.len); // not including NUL
                    try w.writeInt(u32, len_u32);
                    try w.buffer.appendSlice(w.allocator, this.value);
                    try w.buffer.append(w.allocator, 0);
                },
                'g' => {
                    try w.padTo(1);
                    const n = this.value.len;
                    if (n > 255) return error.SignatureTooLong;
                    try w.buffer.append(w.allocator, @as(u8, @intCast(n)));
                    try w.buffer.appendSlice(w.allocator, this.value);
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

        pub fn new(value: bool) @This() {
            return .{ .value = value, .repr = &rr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            try w.padTo(dbusAlignOf(bool)); // 4
            try w.writeInt(u32, @intFromBool(this.value));
        }
    };
}

/// Unsigned 32-bit integer representing an index into an out-of-band array of
/// file descriptors, transferred via some platform-specific mechanism (mnemonic: h for handle)
pub fn UnixFd() type {
    const repr_len = reprLength(u32);
    return struct {
        handle: u32,
        repr: []const u8,

        pub fn new(handle: u32) @This() {
            var repr_arr: [repr_len]u8 = @splat(0);
            repr_arr[0] = 'h';
            return .{ .handle = handle, .repr = &repr_arr };
        }

        pub fn ser(this: @This(), w: *DBusWriter) !void {
            try w.padTo(4);
            try w.writeInt(u32, this.handle);
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
