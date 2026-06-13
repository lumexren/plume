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

const Connection = @import("Connection.zig");
const Message = @import("Message.zig");

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Represents a handler for a D-Bus signal.
pub const SignalHandler = struct {
    interface: []const u8,
    member: []const u8,
    callback: *const fn (ctx: ?*anyopaque, message: Message) void,
    ctx: ?*anyopaque,
};

pub const InterfaceWrapper = struct {
    instance: *anyopaque,
    dispatch: *const fn (wrapper: *const InterfaceWrapper, conn: *Connection, message: Message) anyerror!void,
    destroy: *const fn (wrapper: *const InterfaceWrapper, allocator: Allocator) void,
    interface_name: [:0]const u8,
    path: [:0]const u8,
    intro_xml: [:0]const u8,
};
