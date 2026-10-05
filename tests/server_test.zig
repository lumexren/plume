const std = @import("std");
const plume = @import("plume");
const Connection = plume.Connection;
const signal = plume.signal;
const GStr = plume.Value.GStr;

const MyInterface = struct {
    conn: *Connection,
    ThisIsAProps: plume.Property(i32, .ReadWrite) = .init(43),
    thisIsAsignal: plume.Signal(GStr) = .init("thisIsAsignal"),

    pub const INTERFACE_NAME = "dev.myinterface.test";

    pub fn init(conn: *Connection, _: void) @This() {
        return MyInterface{
            .conn = conn,
        };
    }

    pub fn Testing(self: *MyInterface) !GStr {
        std.debug.print("MyInterface.Testing called!\n", .{});
        std.debug.print("Prop value: {d}\n", .{self.ThisIsAProps.value});
        try self.thisIsAsignal.trigger(self.conn, GStr.new("from the random Signal"));
        return GStr.new("Hello");
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("Initializing connection...\n", .{});
    // NOTE: This requires a running DBus session bus.
    var conn: Connection = try .init(init.io, allocator, .Session, init.environ_map);
    defer conn.close();

    std.debug.print("Registering interface {s}...\n", .{MyInterface.INTERFACE_NAME});
    try conn.registerObject(MyInterface, "dev.myinterface.test", "/dev/myinterface/test", {});

    std.debug.print("Service registered. Ready to serve requests.\n", .{});

    // Uncomment to run loop:
    try conn.serve();
}
