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

/// Represents the header of a D-Bus message.
const Header = @This();

pub const Field = @import("Field.zig");
pub const Type = @import("Type.zig").Type;

const Value = @import("../../value/root.zig");
const dbusAlignOf = Value.dbusAlignOf;
const DBusWriter = @import("../../DBusWriter.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const math = std.math;
const lang = std.lang;
const Endian = lang.Endian;
const Allocator = std.mem.Allocator;

/// Errors that can occur when packing a D-Bus message header.
pub const HeaderError = error{
    ArrayTooLarge,
};

/// Endianness flag; ASCII 'l' for little-endian or ASCII 'B' for big-endian.
/// Both header and body are in this endianness.
/// By default this library default to the native endian.
endianess: Endian = .native,
/// Message type. Unknown types must be ignored
message_type: Type,
/// Bitwise OR of flags. Unknown flags must be ignored.
flags: u8,
/// Major protocol version of the sending application. If the major protocol
/// version of the receiving application does not match, the applications
/// will not be able to communicate and the D-Bus connection must be
/// disconnected. The major protocol version for this version of the
/// specification is 1.
proto_version: u8,

/// Length in bytes of the message body, starting from the end of the header.
/// The header ends after its alignment padding to an 8-boundary.
body_length: u32,
/// The serial of this message, used as a cookie by the sender to identify
/// the reply corresponding to this request. This must not be zero.
serial: u32,

/// An array of zero or more header fields where the byte is the field code,
/// and the variant is the field value. The message type determines which
/// fields are required.
header_fields: []const Field,

/// Packs the message header into its wire format.
pub fn pack(this: Header, allocator: Allocator) !ArrayList(u8) {
    const Byte = Value.Byte();
    const U32 = Value.Uint32();

    var buf: ArrayList(u8) = try .initCapacity(allocator, 256);
    var w: DBusWriter = .init(allocator, &buf, this.endianess);

    const order_char: u8 = switch (this.endianess) {
        .little => 'l',
        .big => 'B',
    };

    try Byte.new(order_char).ser(&w);

    try Byte.new(@intFromEnum(this.message_type)).ser(&w);
    try Byte.new(this.flags).ser(&w);
    try Byte.new(this.proto_version).ser(&w);

    try U32.new(this.body_length).ser(&w);
    try U32.new(this.serial).ser(&w);

    // 4) Array of header fields
    // Array length is u32 (4-aligned). Header is currently 12 bytes.
    // 12 % 4 == 0, so no padding needed for the length itself.
    const len_pos = buf.items.len;
    try buf.appendNTimes(allocator, 0, 4);

    const start_elems = buf.items.len;
    // Each element: 8-aligned struct:
    //   field[0]: BYTE code (1-aligned)
    //   field[1]: VARIANT (1-aligned) => write 'g' + payload
    for (this.header_fields) |hf| {
        try w.padTo(8);
        try Byte.new(@intFromEnum(hf.code)).ser(&w);
        try serHeaderFieldVariant(hf.value, &w);
    }

    // Patch array byte length
    const arr_bytes = buf.items.len - start_elems;
    if (arr_bytes > math.maxInt(u32)) return HeaderError.ArrayTooLarge;
    w.writeU32At(len_pos, @intCast(arr_bytes));

    const header_length = buf.items.len;
    const padding_needed = (8 - (header_length % 8)) % 8;
    if (padding_needed > 0) {
        try buf.appendNTimes(allocator, 0, padding_needed);
    }

    // 5) Pad header to 8
    try w.padTo(8);

    return buf;
}

// Serializes a HeaderFieldValue as a D-Bus VARIANT.
fn serHeaderFieldVariant(hfv: Field.Value, w: *DBusWriter) !void {
    // We inline the variant emission: 'g' then aligned payload.
    switch (hfv) {
        .Path => |s| {
            // VARIANT signature = 's' (object path uses string encoding on the wire)
            try w.writeSignatureOf(Value.GPath); // signature 's'
            try w.padTo(dbusAlignOf(Value.GPath));
            try Value.ObjectPath().new(s).ser(w);
        },
        .Interface => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Member => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .ErrorName => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Destination => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Sender => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Signature => |sig| {
            try w.writeSignatureOf(Value.GSig); // inner type is 'g'
            try w.padTo(dbusAlignOf(Value.GSig)); // 1
            try Value.Signature().new(sig).ser(w);
        },
        .ReplySerial => |u| {
            try w.writeSignatureOf(u32);
            try w.padTo(dbusAlignOf(u32)); // 4
            try Value.Uint32().new(u).ser(w);
        },
        .UnixFds => |u| {
            try w.writeSignatureOf(u32);
            try w.padTo(dbusAlignOf(u32)); // 4
            try Value.Uint32().new(u).ser(w);
        },
    }
}
