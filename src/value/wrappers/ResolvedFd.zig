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

/// A resolved file descriptor providing the active OS descriptor handle and D-Bus wire index.
const ResolvedFd = @This();

handle: std.posix.fd_t,
index: u32 = 0,

pub fn init(handle: std.posix.fd_t, index: u32) ResolvedFd {
    return .{ .handle = handle, .index = index };
}

/// Duplicates the file descriptor with O_CLOEXEC for persistent use beyond the request/method scope.
pub fn duplicate(this: ResolvedFd) !std.posix.fd_t {
    const new_fd = std.posix.system.fcntl(this.handle, std.posix.F.DUPFD_CLOEXEC, 0);
    const err = std.posix.errno(new_fd);
    if (err != .SUCCESS) return error.DupFailed;
    return @intCast(new_fd);
}
