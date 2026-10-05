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

const SocketReader = @This();

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Mutex = Io.Mutex;

interface: Io.Reader,
fd: posix.fd_t,
allocator: Allocator,
mutex: Mutex = .init,
io: Io,
received_fds: ArrayList(posix.fd_t),

pub fn init(fd: posix.fd_t, allocator: Allocator, io: Io, buffer: []u8) !SocketReader {
    return .{
        .interface = .{
            .vtable = &.{
                .stream = streamImpl,
                .readVec = readVec,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .fd = fd,
        .allocator = allocator,
        .mutex = .init,
        .io = io,
        .received_fds = try .initCapacity(allocator, 0),
    };
}

pub fn deinit(this: *SocketReader) void {
    this.mutex.lockUncancelable(this.io);
    defer this.mutex.unlock(this.io);
    for (this.received_fds.items) |fd| {
        _ = posix.system.close(fd);
    }
    this.received_fds.deinit(this.allocator);
}

fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(io_r, &data);
    io_w.advance(n);
    return n;
}

fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const this: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));
    var iovecs_buffer: [8]posix.iovec = undefined;
    const dest_n, const data_size = try io_r.writableVectorPosix(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];

    while (true) {
        const n = this.recvWithIovecs(dest) catch |err| switch (err) {
            error.WouldBlock => return error.ReadFailed,
            error.Interrupted => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.EndOfStream;

        if (n > data_size) {
            this.interface.end += n - data_size;
            return data_size;
        }
        return n;
    }
}

fn recvWithIovecs(this: *SocketReader, iov: []posix.iovec) !usize {
    const MaxFds = 32;
    const cmsg_align = @alignOf(usize);
    const cmsg_hdr_len = comptime mem.alignForward(usize, @sizeOf(std.c.cmsghdr), cmsg_align);
    const CmsgSpace = comptime cmsg_hdr_len + mem.alignForward(usize, MaxFds * @sizeOf(posix.fd_t), cmsg_align);
    var cmsg_buf: [CmsgSpace]u8 align(@alignOf(std.c.cmsghdr)) = undefined;

    var msg = posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = iov.ptr,
        .iovlen = iov.len,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    const flags: u32 = if (@hasDecl(posix.MSG, "CMSG_CLOEXEC")) posix.MSG.CMSG_CLOEXEC else 0;
    const rc = posix.system.recvmsg(this.fd, &msg, flags);
    const err = posix.errno(rc);
    if (err != .SUCCESS) {
        if (err == .INTR) return error.Interrupted;
        if (err == .AGAIN) return error.WouldBlock;
        return error.ReadFailed;
    }
    const bytes_read: usize = @intCast(rc);
    if (bytes_read == 0) return 0;

    if (msg.controllen >= @sizeOf(std.c.cmsghdr) and msg.control != null) {
        var offset: usize = 0;
        while (offset + @sizeOf(std.c.cmsghdr) <= msg.controllen) {
            const cmsg: *const std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf[offset]));
            if (cmsg.len < @sizeOf(std.c.cmsghdr) or offset + cmsg.len > msg.controllen) break;

            if (cmsg.level == posix.SOL.SOCKET and cmsg.type == posix.SCM.RIGHTS) {
                if (cmsg.len > cmsg_hdr_len) {
                    const data_len = cmsg.len - cmsg_hdr_len;
                    const fd_count = data_len / @sizeOf(posix.fd_t);
                    const fds_ptr: [*]const posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[offset + cmsg_hdr_len]));
                    this.mutex.lockUncancelable(this.io);
                    defer this.mutex.unlock(this.io);
                    for (0..fd_count) |i| {
                        const fd = fds_ptr[i];
                        if (flags == 0) {
                            _ = posix.system.fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
                        }
                        try this.received_fds.append(this.allocator, fd);
                    }
                }
            }

            const cmsg_aligned = mem.alignForward(usize, cmsg.len, cmsg_align);
            if (cmsg_aligned == 0) break;
            offset += cmsg_aligned;
        }
    }
    return bytes_read;
}
