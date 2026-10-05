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

const Connection = @import("Connection.zig");
const Encoder = @import("Encoder.zig");
const Message = @import("Message.zig");
const MessageHeader = Message.MessageHeader;
const MessageHeaderField = MessageHeader.HeaderField;

const std = @import("std");

/// Signal definition helper.
/// Returns a type that represents a signal carrying a payload of type T.
pub fn Signal(comptime T: type) type {
    return struct {
        name: [:0]const u8,
        interface: ?[:0]const u8 = null,
        path: ?[:0]const u8 = null,
        // Marker to identify this struct
        pub const __is_plume_signal = true;
        pub const PayloadType = T;

        /// Triggers a signal.
        /// `conn`: The connection to send the signal on.
        /// `payload`: The payload matching the signal's type.
        pub fn trigger(this: *@This(), connection: *Connection, payload: T) !void {
            const interface = this.interface orelse return error.SignalNotBound;
            const path = this.path orelse return error.SignalNotBound;

            var encoder: Encoder = try .encode(connection.allocator, payload);
            defer encoder.deinit();

            const serial = connection.nextSerial();

            const header: MessageHeader = .{
                .message_type = .Signal,
                .flags = 0,
                .proto_version = 1,
                .body_length = @intCast(encoder.body().len),
                .serial = serial,
                .header_fields = @constCast(&[_]MessageHeaderField{
                    .{ .code = .Path, .value = .{ .Path = path } },
                    .{ .code = .Interface, .value = .{ .Interface = interface } },
                    .{ .code = .Member, .value = .{ .Member = this.name } },
                    .{ .code = .Signature, .value = .{ .Signature = encoder.signature() } },
                }),
            };

            const message: Message = .new(header, encoder.body());
            try connection.sendMessage(message);
        }
    };
}

/// Creates a new signal definition.
pub fn signal(name: [:0]const u8, comptime T: type) Signal(T) {
    return .{ .name = name };
}

/// Defines the access permissions for a property.
pub const Access = enum { Read, Write, ReadWrite };

/// Property definition helper.
pub fn Property(comptime T: type, comptime access_mode: Access) type {
    return struct {
        value: T,
        pub const __is_plume_property = true;
        pub const DataType = T;
        pub const AccessMode = access_mode;
    };
}

/// Creates a new property with initial value and access.
pub fn property(comptime T: type, comptime access: Access, value: T) Property(T, access) {
    return .{ .value = value };
}
