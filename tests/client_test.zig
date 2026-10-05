const std = @import("std");
const plume = @import("plume");
const Proxy = plume.Proxy;
const GStr = plume.Value.GStr;

fn onSignal(ctx: *u32, args: @Tuple(&[_]type{GStr})) void {
    ctx.* += 1;
    std.debug.print("CLIENT RECEIVED SIGNAL: dev.myinterface.test.thisIsAsignal with arg: '{s}' (count={d})\n", .{ args[0].s, ctx.* });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var conn: plume.Connection = try .init(
        init.io,
        allocator,
        .Session,
        init.environ_map,
    );
    defer conn.close();

    const p: Proxy = .init(
        &conn,
        "dev.myinterface.test",
        "/dev/myinterface/test",
        "dev.myinterface.test",
    );

    var signal_count: u32 = 0;
    try p.connectSignal(@Tuple(&[_]type{GStr}), "thisIsAsignal", &signal_count, onSignal);

    // Test Introspection
    std.debug.print("Client: Calling Introspect()...\n", .{});
    var intro_res = try p.rawCall("org.freedesktop.DBus.Introspectable", "Introspect", .{});
    defer intro_res.deinit();
    const xml = try intro_res.expect(GStr);
    std.debug.print("Client: Introspection XML:\n{s}\n", .{xml.s});

    std.debug.print("Client: Calling Testing()...\n", .{});
    var result = try p.call("Testing", .{});
    defer result.deinit();

    const s = try result.expect(GStr);
    std.debug.print("Client: Result: {s}\n", .{s.s});
}
