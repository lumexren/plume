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

const SocketIterator = @This();

const std = @import("std");
const mem = std.mem;
const TokenIterator = mem.TokenIterator;

inner: TokenIterator(u8, .scalar),

pub fn init(address: []const u8) SocketIterator {
    return .{ .inner = mem.tokenizeScalar(u8, address, ';') };
}

pub fn next(this: *SocketIterator) ?[]const u8 {
    const prefix = "unix:";
    const param = "path=";

    while (this.inner.next()) |token| {
        if (!mem.startsWith(u8, token, prefix)) continue;

        var params = mem.tokenizeScalar(u8, token[prefix.len..], ',');
        while (params.next()) |pair| {
            if (mem.startsWith(u8, pair, param)) return pair[param.len..];
        }
    }

    return null;
}
