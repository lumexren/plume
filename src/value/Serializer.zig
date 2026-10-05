// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erenvly
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

const Serializer = @This();

const Value = @import("Value.zig");
const GPath = Value.GPath;
const GSig = Value.GSig;
const GStr = Value.GStr;
const GUFd = Value.GUFd;
const ResolvedFd = Value.ResolvedFd;
const DBusWriter = @import("DBusWriter.zig");

const std = @import("std");
const math = std.math;

pub fn trySerialize(comptime T: type, data: T, w: *DBusWriter) !void {
    if (comptime Value.doesImplementSer(T)) {
        try data.ser(w);
        return;
    }

    if (comptime Value.isDict(T)) {
        try w.padTo(4);
        const len_pos = w.buffer.items.len;
        try w.buffer.appendNTimes(w.allocator, 0, 4);

        try w.padTo(8);
        const start_elems = w.buffer.items.len;

        var it = data.iterator();
        while (it.next()) |e| {
            try w.padTo(8); // each dict-entry
            const key = e.key_ptr.*;
            const val = e.value_ptr.*;
            const kv = Value.dictKV(T);
            const K = kv.key;
            const V = kv.val;

            try w.padTo(Value.dbusAlignOf(K));

            if (K == []const u8 or K == [:0]const u8 or K == []u8 or K == [:0]u8) {
                try w.padTo(4);
                try w.writeInt(u32, @intCast(key.len));
                try w.buffer.appendSlice(w.allocator, key);
                try w.buffer.append(w.allocator, 0);
            } else {
                try Serializer.trySerialize(K, key, w);
            }

            try w.padTo(Value.dbusAlignOf(V));
            try Serializer.trySerialize(V, val, w);
        }

        const arr_bytes: usize = w.buffer.items.len - start_elems;
        if (arr_bytes > math.maxInt(u32)) return error.ArrayTooLarge;
        w.writeU32At(len_pos, @intCast(arr_bytes));
        return;
    }

    if (T == GStr) {
        try Value.String().new(data.s).ser(w);
        return;
    } else if (T == GPath) {
        try Value.ObjectPath().new(data.s).ser(w);
        return;
    } else if (T == GSig) {
        try Value.Signature().new(data.s).ser(w);
        return;
    } else if (T == GUFd) {
        try Value.UnixFd().new(data.fd).ser(w);
        return;
    } else if (T == ResolvedFd) {
        try Value.UnixFd().new(data.index).ser(w);
        return;
    }

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits == 8 and info.signedness == .signed) return error.I8CannotBeSerialized;
            if (info.bits == 8) try Value.Byte().new(@as(u8, data)).ser(w) else if (info.bits == 16) if (info.signedness == .signed)
                try Value.Int16().new(@as(i16, data)).ser(w)
            else
                try Value.Uint16().new(@as(u16, data)).ser(w) else if (info.bits == 32) if (info.signedness == .signed)
                try Value.Int32().new(@as(i32, data)).ser(w)
            else
                try Value.Uint32().new(@as(u32, data)).ser(w) else if (info.bits == 64) if (info.signedness == .signed)
                try Value.Int64().new(@as(i64, data)).ser(w)
            else
                try Value.Uint64().new(@as(u64, data)).ser(w) else return error.UnsupportedIntWidth;
        },
        .float => |info| {
            if (info.bits != 64) return error.F32CannotBeSerialized;
            try Value.Double().new(@as(f64, data)).ser(w);
        },
        .bool => {
            try Value.Bool().new(data).ser(w);
        },
        .array => |ai| {
            const Elem = ai.child;
            const slice_view = data[0..];
            try Value.Array(Elem).new(slice_view).ser(w);
        },
        .pointer => |pi| {
            if (pi.size == .slice) {
                const Elem = pi.child;
                try Value.Array(Elem).new(data).ser(w);
            } else if (pi.size == .one) {
                const Elem = pi.child;
                try Serializer.trySerialize(Elem, data.*, w);
            } else return error.UnsupportedTypeForNow;
        },
        .@"struct" => |sinfo| {
            if (sinfo.is_tuple) {
                try Value.Tuple(T).new(data).ser(w);
            } else {
                try Value.Struct(T).new(data).ser(w);
            }
        },
        .@"union" => {
            try Value.Variant(T).new(data).ser(w);
        },
        else => return error.UnsupportedTypeForNow,
    }
}
