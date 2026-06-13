

const std = @import("std");
const plume = @import("plume");
const Connection = plume.Connection;
const Signal = plume.dbus_types.Signal;
const signal = plume.dbus_types.signal;
const GStr = plume.Value.GStr;
const Property = plume.dbus_types.Property;

const MyInterface = struct {
    conn: *Connection,
    ThisIsAProps: Property(i32, .ReadWrite) = plume.dbus_types.property(i32, .ReadWrite, 43),
    thisIsAsignal: Signal(GStr) = signal("thisIsAsignal", GStr),

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
    var conn = try Connection.init(init.io, allocator, init.environ_map, .Session);
    defer conn.close();

    std.debug.print("Registering interface {s}...\n", .{MyInterface.INTERFACE_NAME});
    const handle = try conn.registerObject(MyInterface, "dev.myinterface.test", "/dev/myinterface/test", {});

    std.debug.print("Service registered. Handle: {d}\n", .{handle});
    std.debug.print("Ready to serve requests.\n", .{});

    // Uncomment to run loop:
    try conn.waitOnHandle(handle);
}
