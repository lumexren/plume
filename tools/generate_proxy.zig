const std = @import("std");
const plume = @import("plume");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 4) {
        const prog_name = std.fs.path.basename(args[0]);
        std.debug.print("Usage: {s} <destination> <object_path> <bus_type>\n", .{prog_name});
        std.debug.print("\nArguments:\n", .{});
        std.debug.print("  <destination>  The well-known name of the service (e.g. org.freedesktop.DBus)\n", .{});
        std.debug.print("  <object_path>  The object path to introspect (e.g. /org/freedesktop/DBus)\n", .{});
        std.debug.print("  <bus_type>     The bus to connect to: 'Session' or 'System'\n", .{});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} org.freedesktop.DBus /org/freedesktop/DBus Session\n", .{prog_name});
        return;
    }

    const dest = args[1];
    const path = args[2];
    const bustype = std.meta.stringToEnum(plume.BusType, args[3]) orelse {
        std.debug.print("Invalid bus type '{s}'. Expected 'Session' or 'System'\n", .{args[3]});
        return;
    };

    var conn: plume.Connection = try .init(io, allocator, bustype, init.environ_map);
    defer conn.close();

    const dbus_proxy: plume.Proxy = .init(&conn, @ptrCast(dest), @ptrCast(path), "org.freedesktop.DBus.Introspectable");
    var result = try dbus_proxy.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer result.deinit();

    const xml = try result.expect(plume.Value.GStr);

    const node = try plume.introspection.parse(allocator, xml.s);
    defer node.deinit(allocator);

    var writer = std.Io.File.stdout().writerStreaming(init.io, try allocator.alloc(u8, 0x100));
    defer allocator.free(writer.interface.buffer);

    try plume.generator.generate(&writer.interface, node, dest, path);
    try writer.flush();
}
