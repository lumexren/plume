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

/// A local representation of a remote D-Bus object.
const Proxy = @This();

const Value = @import("Value.zig");
const Message = @import("Message.zig");
const MethodResult = @import("MethodResult.zig");
const Connection = @import("Connection.zig");
const Decoder = @import("Decoder.zig");
const Encoder = @import("Encoder.zig");

const GStr = Value.GStr;
const GPath = Value.GPath;
const GSig = Value.GSig;
const GUFd = Value.GUFd;

const std = @import("std");

connection: *Connection,
destination: [:0]const u8,
path: [:0]const u8,
interface: [:0]const u8,

/// Creates a new Proxy for a remote object.
/// `destination`: The well-known name or unique name of the destination connection.
/// `path`: The object path on the destination.
/// `interface`: The default interface to use for method calls.
pub fn init(connection: *Connection, destination: [:0]const u8, path: [:0]const u8, interface: [:0]const u8) Proxy {
    return .{ .connection = connection, .destination = destination, .path = path, .interface = interface };
}

/// Performs a low-level method call on a specific interface.
pub fn rawCall(this: Proxy, iface: [:0]const u8, method: [:0]const u8, args: anytype) !MethodResult {
    var encoder: Encoder = try .encode(this.connection.allocator, args);
    defer encoder.deinit();

    const reply = try this.connection.methodCall(this.destination, this.path, iface, method, encoder.signature(), encoder.body());

    if (reply.isError()) {
        const err_name = reply.getErrorName() orelse "UnknownError";
        var decoder: Decoder = .from(this.connection.allocator, reply);
        const err_msg = decoder.decode(GStr) catch GStr.new("(no error message)");
        std.debug.print("[plume] DBus Error: {s}: {s}\n", .{ err_name, err_msg.s });
        this.connection.freeMessage(@constCast(&reply));
        return error.RemoteError;
    }

    return .{ .message = reply, .connection = this.connection, .allocator = this.connection.allocator };
}

/// Invokes a method on the remote object using the default interface.
/// `args` can be a single value or a tuple of values.
/// Returns a MethodResult owning the reply message.
pub fn call(this: Proxy, method: [:0]const u8, args: anytype) !MethodResult {
    return this.rawCall(this.interface, method, args);
}

/// Helper to get a property value.
/// T must be a union (Variant) that can hold the expected property type.
/// D-Bus Get returns a Variant ('v').
/// The returned value is allocated using the connection's allocator if it contains strings or slices.
pub fn getProperty(this: Proxy, comptime T: type, name: [:0]const u8) !T {
    var result = try this.rawCall("org.freedesktop.DBus.Properties", "Get", .{ GStr.new(this.interface), GStr.new(name) });
    defer result.deinit();

    var dec: Decoder = .from(this.connection.allocator, result.message);
    return try dec.decodeAlloc(T);
}

/// Helper to set a property value.
/// `value` must be a union (Variant) representing the new value.
pub fn setProperty(this: Proxy, name: [:0]const u8, value: anytype) !void {
    var result = try this.rawCall("org.freedesktop.DBus.Properties", "Set", .{ GStr.new(this.interface), GStr.new(name), value });
    result.deinit();
}
