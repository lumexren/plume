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

//! Plume is a modern, fast, and easy-to-use D-Bus library for Zig.
//! It provides a type-safe, minimal-allocation API for D-Bus communication.
//! It is designed to be used in both userspace applications and
//! as a foundation for more complex D-Bus implementations.

pub const Decoder = @import("Decoder.zig");
pub const Encoder = @import("Encoder.zig");
pub const Connection = @import("Connection.zig");
pub const DBusWriter = @import("DBusWriter.zig");
pub const Message = @import("message/root.zig");
pub const MethodResult = @import("MethodResult.zig");
pub const Proxy = @import("Proxy.zig");
pub const Serializer = @import("Serializer.zig");
pub const SocketIterator = @import("SocketIterator.zig");
pub const Value = @import("value/root.zig");
pub const InterfaceWrapper = @import("InterfaceWrapper.zig");
pub const SignalHandler = @import("SignalHandler.zig");

pub const introspection = @import("introspection.zig");
pub const generator = @import("generator.zig");
pub const xml_generator = @import("xml_generator.zig");

pub const dbus_types = @import("dbus_types.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
