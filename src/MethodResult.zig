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

/// Result of a D-Bus method call.
/// Owns the reply message and provides methods to decode its body.
const MethodResult = @This();

const Message = @import("message/root.zig");
const Connection = @import("Connection.zig");
const Decoder = @import("Decoder.zig");

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

message: Message,
connection: *Connection,
allocator: Allocator,

/// Releases resources associated with the result message.
pub fn deinit(this: *MethodResult) void {
    this.connection.freeMessage(&this.message);
}

/// Returns a BodyDecoder to read the result body.
/// Note: The decoder's lifetime is tied to the result.
pub fn reader(this: *MethodResult) Decoder {
    return .from(this.allocator, this.message);
}

/// Convenience method to decode a single value of type T from the reply body.
/// Note: The MethodResult must still be explicitly deinitialized after use
/// if T borrows memory (like strings or slices) from the message body.
pub fn expect(this: *MethodResult, comptime T: type) !T {
    var dec = this.reader();
    return try dec.decode(T);
}

/// Decodes a single value of type T from the reply body and deep-copies any allocated memory
/// using the connection's allocator.
pub fn expectAlloc(this: *MethodResult, comptime T: type) !T {
    var dec = this.reader();
    return try dec.decodeAlloc(T);
}
