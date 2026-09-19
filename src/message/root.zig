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

/// Represents a D-Bus message, including its header and body.
const Message = @This();

pub const Flag = @import("Flag.zig").Flag;
pub const Header = @import("header/root.zig");
pub const Type = Header.Type;

const DBusWriter = @import("../DBusWriter.zig");
const Value = @import("../value/root.zig");
const dbusAlignOf = Value.dbusAlignOf;

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const lang = std.lang;
const Endian = lang.Endian;

header: Header,
body: []const u8,
allocator: Allocator = undefined,

/// Creates a new Message.
pub fn new(header: Header, body: []const u8) Message {
    return .{ .header = header, .body = body, .allocator = undefined };
}

/// Packs the message into its wire format.
pub fn pack(this: Message, allocator: Allocator) !ArrayList(u8) {
    // Ensure header has correct body_length
    var hdr = this.header;
    hdr.body_length = @intCast(this.body.len);

    var header_bytes = try hdr.pack(allocator);
    errdefer header_bytes.deinit(allocator);

    // The message is: header || body (body itself must already be validly marshalled)
    try header_bytes.appendSlice(allocator, this.body);
    return header_bytes;
}

/// Checks if the message is a signal with the given interface and member names.
pub fn isSignal(this: Message, interface: []const u8, member: []const u8) bool {
    if (this.header.message_type != .Signal) return false;
    var has_iface = false;
    var has_member = false;

    for (this.header.header_fields) |f| {
        switch (f.value) {
            .Interface => |s| if (mem.eql(u8, s, interface)) {
                has_iface = true;
            },
            .Member => |s| if (mem.eql(u8, s, member)) {
                has_member = true;
            },
            else => {},
        }
    }

    return has_iface and has_member;
}

/// Checks if the message is an Error.
pub fn isError(this: Message) bool {
    return this.header.message_type == .Error;
}

/// Returns the ErrorName if the message is an Error, otherwise null.
pub fn getErrorName(this: Message) ?[]const u8 {
    if (!this.isError()) return null;
    for (this.header.header_fields) |f| {
        if (f.code == .ErrorName) return f.value.ErrorName;
    }

    return null;
}
