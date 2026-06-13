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

const Serializer = @This();

const Value = @import("Value.zig");
const DBusWriter = @import("DBusWriter.zig");

const GStr = Value.GStr;
const GPath = Value.GPath;
const GSig = Value.GSig;
const GUFd = Value.GUFd;

pub const SerializerError = error{
    I8CannotBeSerialized,
    UnSupportedIntWidth,
    F32CannotBeSerialized,
    UnSupportedTypeForNow,
};

pub fn trySerialize(comptime T: type, data: T, w: *DBusWriter) !void {
    if (comptime Value.doesImplementSer(T)) {
        try data.ser(w);
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
    }

    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.bits == 8 and info.signedness == .signed) return SerializerError.I8CannotBeSerialized;
            if (info.bits == 8) try Value.Byte().new(@as(u8, data)).ser(w) else if (info.bits == 16) if (info.signedness == .signed)
                try Value.Int16().new(@as(i16, data)).ser(w)
            else
                try Value.Uint16().new(@as(u16, data)).ser(w) else if (info.bits == 32) if (info.signedness == .signed)
                try Value.Int32().new(@as(i32, data)).ser(w)
            else
                try Value.Uint32().new(@as(u32, data)).ser(w) else if (info.bits == 64) if (info.signedness == .signed)
                try Value.Int64().new(@as(i64, data)).ser(w)
            else
                try Value.Uint64().new(@as(u64, data)).ser(w) else return SerializerError.UnsupportedIntWidth;
        },
        .float => |info| {
            if (info.bits != 64) return SerializerError.F32CannotBeSerialized;
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
            } else return SerializerError.UnsupportedTypeForNow;
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
        else => return SerializerError.UnsupportedTypeForNow,
    }
}
