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

const DBusWriter = @This();

const Value = @import("Value.zig");

const utils = @import("utils.zig");
const convertInteger = utils.convertInteger;

const std = @import("std");
const lang = std.lang;
const Endian = lang.Endian;
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

allocator: Allocator,
buffer: *ArrayList(u8),
endian: Endian,
body_start_offset: usize,

pub inline fn init(allocator: Allocator, buffer: *ArrayList(u8), endian: Endian) DBusWriter {
    return .{ .allocator = allocator, .buffer = buffer, .endian = endian, .body_start_offset = 0 };
}

pub fn padTo(this: *DBusWriter, @"align": usize) !void {
    if (@"align" <= 1) return;
    const abs_len = this.body_start_offset + this.buffer.items.len;
    const rem = abs_len % @"align";
    if (rem != 0) try this.buffer.appendNTimes(this.allocator, 0, @"align" - rem);
}

pub fn writeInt(this: *DBusWriter, comptime T: type, x: T) !void {
    const bytes = convertInteger(T, x, this.endian);
    try this.buffer.appendSlice(this.allocator, &bytes);
}

pub fn writeU32At(this: *DBusWriter, pos: usize, v: u32) void {
    var b: [4]u8 = convertInteger(u32, v, this.endian);
    @memcpy(this.buffer.items[pos .. pos + 4], &b);
}

pub fn writeSignatureOf(this: *DBusWriter, comptime T: type) !void {
    const sig_len = Value.reprLength(T);
    if (sig_len > 255) return error.SignatureTooLong;
    var sig: [sig_len]u8 = undefined;
    Value.getRepr(T, sig_len, 0, &sig);

    // 'g' encoding: u8 length (no NUL), bytes, NUL; 1-aligned
    try this.padTo(1);
    try this.buffer.append(this.allocator, @as(u8, @intCast(sig_len)));
    try this.buffer.appendSlice(this.allocator, &sig);
    try this.buffer.append(this.allocator, 0);
}
