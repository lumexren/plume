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

const std = @import("std");
const process = std.process;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const debug = std.debug;
const meta = std.meta;

const plume = @import("plume");

pub fn main(init: process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        const prog_name = Dir.path.basename(args[0]);
        debug.print("Usage: {s} <destination> <object_path> <bus_type>\n", .{prog_name});
        debug.print("\nArguments:\n", .{});
        debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
        debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
        debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
        debug.print("\nExample:\n", .{});
        debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});

        return;
    }

    const dest = args[1];
    const path = args[2];
    const bustype = meta.stringToEnum(plume.Connection.BusType, args[3]).?;

    var conn: plume.Connection = try .init(io, allocator, init.environ_map, bustype);
    defer conn.close();

    const dbus_proxy: plume.Proxy = .init(&conn, @ptrCast(dest), @ptrCast(path), "org.freedesktop.DBus.Introspectable");
    var result = try dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer result.deinit();

    const xml = try result.expect(plume.Value.GStr);

    const node = try plume.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    const generated = try plume.generator.generate(allocator, node, dest, path);
    defer allocator.free(generated);

    try File.writeStreamingAll(.stdout(), init.io, generated);
}
