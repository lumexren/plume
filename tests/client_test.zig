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
const debug = std.debug;
const process = std.process;

const plume = @import("plume");
const Proxy = plume.Proxy;
const GStr = plume.Value.GStr;

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;

    var conn: plume.Connection = try .init(init.io, allocator, init.environ_map, .Session);
    defer conn.close();

    try conn.addMatch("type='signal',interface='dev.myinterface.test'");

    const Handler = struct {
        fn onSignal(_: ?*anyopaque, msg: plume.Message) void {
            var iface: []const u8 = "unknown";
            var member: []const u8 = "unknown";
            for (msg.header.header_fields) |f| {
                switch (f.value) {
                    .Interface => |s| iface = s,
                    .Member => |s| member = s,
                    else => {},
                }
            }

            debug.print("CLIENT RECEIVED SIGNAL: {s}.{s}\n", .{ iface, member });
        }
    };

    try conn.registerSignalHandler("dev.myinterface.test", "thisIsAsignal", Handler.onSignal, null);

    const p = Proxy.init(&conn, "dev.myinterface.test", "/dev/myinterface/test", "dev.myinterface.test");

    // Test Introspection
    debug.print("Client: Calling Introspect()...\n", .{});
    var intro_res = try p.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer intro_res.deinit();
    const xml = try intro_res.expect(GStr);
    debug.print("Client: Introspection XML:\n{s}\n", .{xml.s});

    debug.print("Client: Calling Testing()...\n", .{});
    var result = try p.call("Testing", .{});
    defer result.deinit();

    const s = try result.expect(GStr);
    debug.print("Client: Result: {s}\n", .{s.s});
}
