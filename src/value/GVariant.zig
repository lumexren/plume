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

pub const GVariantTag = @import("GVariantTag.zig").GVariantTag;

const GUFd = @import("GUFd.zig");
const GStr = @import("GStr.zig");
const GPath = @import("GPath.zig");
const GSig = @import("GSig.zig");

const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;

pub const GVariant = union(GVariantTag) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,

    ufd: GUFd,
    string: GStr,
    object_path: GPath,
    signature: GSig,

    array: []GVariant,
    tuple: []GVariant,
    dict: StringHashMap(GVariant),

    /// Variants can nest variants
    variant: *GVariant,

    pub fn deinit(this: *GVariant, allocator: Allocator) void {
        switch (this.*) {
            .string => |s| allocator.free(s.s),
            .object_path => |o| allocator.free(o.s),
            .signature => |s| allocator.free(s.s),
            .array, .tuple => |arr| {
                for (arr) |*item| item.deinit(allocator);
                allocator.free(arr);
            },
            .dict => |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
            .variant => |v| {
                v.deinit(allocator);
                allocator.destroy(v);
            },
            else => {},
        }
    }
};