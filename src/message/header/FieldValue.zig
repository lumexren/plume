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

const FieldValueTag = @import("FieldValueTag.zig").FieldValueTag;

const DBusWriter = @import("../../DBusWriter.zig");
const Value = @import("../../value/root.zig");

/// A union representing the value of a D-Bus message header field.
pub const FieldValue = union(FieldValueTag) {
    Path: [:0]const u8,
    Interface: [:0]const u8,
    Member: [:0]const u8,
    ErrorName: [:0]const u8,
    ReplySerial: u32,
    Destination: [:0]const u8,
    Sender: [:0]const u8,
    Signature: [:0]const u8,
    UnixFds: u32,

    pub fn ser(this: FieldValue, w: *DBusWriter) !void {
        const Sig = Value.Signature();
        const Str = Value.String();
        const Path = Value.ObjectPath();
        const U32 = Value.Uint32();

        switch (this) {
            .UnixFds, .ReplySerial => |x| {
                try U32.new(x).ser(&w);
            },
            .Path => |v| {
                try Path.new(v).ser(&w);
            },
            .Interface, .Member, .ErrorName, .Destination, .Sender => |v| {
                try Str.new(v).ser(&w);
            },
            .Signature => |v| {
                try Sig.new(v).ser(&w);
            },
        }
    }
};
