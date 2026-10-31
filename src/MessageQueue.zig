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

const MessageQueue = @This();

const Message = @import("Message.zig");
const Connection = @import("Connection.zig");

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Mutex = Io.Mutex;
const Allocator = std.mem.Allocator;
const atomic = std.atomic;

list: ArrayList(Message) = .empty,
mutex: Mutex = .init,
cond: Io.Condition = .init,
io: Io,
allocator: Allocator,

pub fn init(io: Io, allocator: Allocator) MessageQueue {
    return .{ .io = io, .allocator = allocator };
}

pub fn deinit(this: *MessageQueue, connection: *Connection) void {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    for (this.list.items) |*message| connection.freeMessage(message);
    this.list.deinit(this.allocator);
}

pub fn push(this: *MessageQueue, message: Message) !void {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    try this.list.append(this.allocator, message);
    this.cond.signal(this.io);
}

pub fn popOrWait(this: *MessageQueue, is_running: *atomic.Value(bool)) ?Message {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    while (this.list.items.len == 0) {
        if (!is_running.load(.acquire)) return null;
        this.cond.waitUncancelable(this.io, &this.mutex);
    }

    return this.list.orderedRemove(0);
}

pub fn wakeAll(this: *MessageQueue) void {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    this.cond.broadcast(this.io);
}
