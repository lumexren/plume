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

const std = @import("std");
const Endian = std.lang.Endian;
const mem = std.mem;

pub inline fn convertInteger(comptime T: type, x: T, endianess: Endian) [@sizeOf(@TypeOf(x))]u8 {
    comptime switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("convertInteger expects an integer type"),
    };
    return mem.toBytes(mem.nativeTo(T, x, endianess));
}

pub inline fn readInteger(comptime T: type, data: *const [@sizeOf(T)]u8, endianess: Endian) T {
    comptime switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("readInteger expects an integer type"),
    };
    return mem.toNative(T, mem.bytesToValue(T, data), endianess);
}
