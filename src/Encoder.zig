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

/// Helper to encode a set of values into a D-Bus message body.
const Encoder = @This();

const DBusWriter = @import("DBusWriter.zig");
const Serializer = @import("Serializer.zig");

const std = @import("std");
const lang = std.lang;
const Endian = lang.Endian;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const Value = @import("value/root.zig");
const dbusAlignOf = Value.dbusAlignOf;

allocator: Allocator,
body_list: ArrayList(u8),
signature_list: ArrayList(u8),
endian: Endian = .little,

/// Encodes a single value or a tuple of values into a new BodyEncoder.
pub fn encode(allocator: Allocator, values: anytype) !Encoder {
    var self: Encoder = .{
        .allocator = allocator,
        .body_list = try .initCapacity(allocator, 256),
        .signature_list = try .initCapacity(allocator, 32),
    };

    errdefer self.deinit();

    const T = @TypeOf(values);
    const type_info = @typeInfo(T);

    if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
        inline for (values) |v| {
            try self.appendValue(v);
        }
    } else {
        try self.appendValue(values);
    }

    // Ensure signature is null-terminated
    try self.signature_list.append(allocator, 0);

    return self;
}

/// Releases resources used by the encoder.
pub fn deinit(this: *Encoder) void {
    this.body_list.deinit(this.allocator);
    this.signature_list.deinit(this.allocator);
}

/// Appends a single value to the encoder's body and signature lists (internal helper).
fn appendValue(this: *Encoder, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == void) return;
    const sig_len = Value.reprLength(T);
    var sig_buf: [256]u8 = undefined;
    Value.getRepr(T, sig_len, 0, sig_buf[0..sig_len]);
    try this.signature_list.appendSlice(this.allocator, sig_buf[0..sig_len]);

    var writer: DBusWriter = .init(this.allocator, &this.body_list, this.endian);
    try writer.padTo(dbusAlignOf(T));

    try Serializer.trySerialize(T, value, &writer);
}

/// Returns the encoded body bytes.
pub fn body(this: Encoder) []const u8 {
    return this.body_list.items;
}

/// Returns the generated signature string.
pub fn signature(this: Encoder) [:0]const u8 {
    return this.signature_list.items[0 .. this.signature_list.items.len - 1 :0];
}
