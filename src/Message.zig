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

/// Represents a D-Bus message, including its header and body.
const Message = @This();

pub const MessageHeader = @import("MessageHeader.zig");
pub const MessageType = MessageHeader.MessageType;
pub const MessageFlag = MessageHeader.MessageFlag;
pub const MessageHeaderField = MessageHeader.HeaderField;
pub const MessageHeaderFieldCode = MessageHeader.HeaderFieldCode;
pub const MessageHeaderFieldValue = MessageHeader.HeaderFieldValue;
pub const MessageHeaderFieldValueTag = MessageHeader.HeaderFieldValueTag;

const Value = @import("value/Value.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

header: MessageHeader,
body: []const u8,
fds: []const std.posix.fd_t = &.{},
allocator: ?Allocator = null,

/// Creates a new Message.
pub fn new(header: MessageHeader, body: []const u8) Message {
    return .{ .header = header, .body = body, .fds = &.{}, .allocator = null };
}

/// Creates a new Message with attached file descriptors.
pub fn newWithFds(header: MessageHeader, body: []const u8, fds: []const std.posix.fd_t) Message {
    return .{ .header = header, .body = body, .fds = fds, .allocator = null };
}

/// Transfers ownership of the attached file descriptors to the caller.
pub fn takeFds(this: *Message, alloc: Allocator) ![]std.posix.fd_t {
    if (this.fds.len == 0) return &.{};

    for (this.fds) |fd| {
        if (fd < 0) return error.AlreadyTaken;
    }

    const result = try alloc.dupe(std.posix.fd_t, this.fds);

    const mutable_fds: []std.posix.fd_t = @constCast(this.fds);
    for (mutable_fds) |*fd| {
        fd.* = -1;
    }

    return result;
}

/// Returns the OS file descriptor corresponding to a D-Bus handle (GUFd index).
pub fn getFd(this: Message, ufd: Value.GUFd) ?std.posix.fd_t {
    if (ufd.fd < this.fds.len) {
        const fd = this.fds[ufd.fd];
        if (fd >= 0) return fd;
    }
    return null;
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
