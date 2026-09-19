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
const process = std.process;
const Io = std.Io;
const Dir = Io.Dir;
const meta = std.meta;
const debug = std.debug;

const plume = @import("plume");
const Proxy = plume.Proxy;
const Message = plume.Message;
const GStr = plume.Value.GStr;

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());

    const prog_path = args.next() orelse "introspector";
    const prog_name = Dir.path.basename(prog_path);

    const dest_arg = args.next();
    const path_arg = args.next();
    const bustype_arg = args.next();

    if (dest_arg == null or path_arg == null or bustype_arg == null) {
        debug.print("Usage: {s} <destination> <object_path> <bus_type>\n", .{prog_name});
        debug.print("\nArguments:\n", .{});
        debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
        debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
        debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
        debug.print("\nExample:\n", .{});
        debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});

        return;
    }

    const dest = dest_arg.?;
    const path = path_arg.?;
    const bustype_string = bustype_arg.?;
    const bustype = meta.stringToEnum(plume.Connection.BusType, bustype_string).?;

    var conn: plume.Connection = try .init(init.io, allocator, init.environ_map, bustype);
    defer conn.close();

    debug.print("Target: {s} {s}\n", .{ dest, path });

    const dbus_proxy: Proxy = .init(&conn, dest, path, "org.freedesktop.DBus.Introspectable");

    var result = dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{}) catch |err| {
        debug.print("Error calling Introspect: {}\n", .{err});
        return;
    };

    defer result.deinit();

    const xml = try result.expect(GStr);

    const node = try plume.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    debug.print("Found {d} interfaces.\n", .{node.interfaces.len});
    for (node.interfaces) |iface| {
        debug.print("\nInterface: {s}\n", .{iface.name});
        for (iface.methods) |m| {
            debug.print("  Method: {s}(", .{m.name});
            for (m.args, 0..) |arg, i| {
                if (i > 0) debug.print(", ", .{});
                if (arg.name.len > 0) {
                    debug.print("{s}: {s}", .{ arg.name, arg.type });
                } else {
                    debug.print("{s}", .{arg.type});
                }
            }
            debug.print(")\n", .{});
        }
    }

    if (node.children.len > 0) {
        debug.print("\nChild nodes:\n", .{});
        for (node.children) |child| {
            debug.print(" - {s}\n", .{child.name});
        }
    }
}
