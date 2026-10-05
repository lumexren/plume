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

const std = @import("std");
const testing = std.testing;

pub const Value = @import("value/Value.zig");
pub const Message = @import("Message.zig");
pub const MessageQueue = @import("MessageQueue.zig");

pub const Proxy = @import("Proxy.zig");
pub const SignalHandler = @import("SignalHandler.zig");
pub const Connection = @import("Connection.zig");
pub const Backend = Connection.Backend;
pub const BusType = Connection.BusType;

pub const introspection = @import("introspection.zig");
pub const generator = @import("generator.zig");
pub const xml_generator = @import("xml_generator.zig");

pub const Encoder = @import("Encoder.zig");
pub const Decoder = @import("Decoder.zig");
pub const MethodResult = @import("MethodResult.zig");
pub const dispatcher = @import("dispatcher.zig");

pub const GUFd = Value.GUFd;
pub const ResolvedFd = Value.ResolvedFd;

pub const SocketReader = @import("SocketReader.zig");

// Re-export types
const dbus_types = @import("dbus_types.zig");
pub const Signal = dbus_types.Signal;
pub const signal = dbus_types.signal;
pub const Property = dbus_types.Property;
pub const property = dbus_types.property;
pub const Access = dbus_types.Access;

test {
    testing.refAllDecls(@This());

    _ = @import("generator.zig");
    _ = @import("value/Value.zig");
    _ = @import("xml_generator.zig");
    _ = @import("dispatcher.zig");
    _ = @import("Decoder.zig");
    _ = @import("Encoder.zig");
    _ = @import("Connection.zig");
    _ = @import("Proxy.zig");
    _ = @import("Message.zig");
    _ = @import("MessageHeader.zig");
    _ = @import("MessageQueue.zig");
    _ = @import("MethodResult.zig");
    _ = @import("SignalHandler.zig");
    _ = @import("SocketIterator.zig");
    _ = @import("SocketReader.zig");
    _ = @import("utils.zig");
}
