## Architecture

plume is designed to be a lightweight, pure-Zig alternative to `libdbus` or `GDBus`.
It handles the entire D-Bus stack, from socket communication to type marshaling.

### Bus Connection

The `Connection` struct manages the Unix Domain Socket and implements the SASL[^1] `EXTERNAL`
authentication handshake. It buffers stream data and runs a blocking message loop
that routes incoming signals and method replies to the appropriate handlers.

### Type System

plume uses compile-time reflection to map Zig types to D-Bus signatures.
Integers, structs, strings, and variants are automatically marshaled into the
D-Bus wire format with correct alignment and endianness. Wrappers like
`GStr` and `GPath` ensure strict type safety for D-Bus specific concepts.

### Method Dispatcher

Standard Zig structs can be exported as D-Bus objects. The library analyzes public
methods and fields to set up automatic routing for method calls. It also generates
introspection XML and exposes `Property` fields via the standard
`org.freedesktop.DBus.Properties` interface.

### Client Proxies

The `Proxy` abstraction simplifies client-side interactions by handling the
construction of method call messages and parsing of replies, hiding the
low-level details of the protocol.

---

### Connecting to the Bus

```zig
const std = @import("std");
const plume = @import("plume");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Connect to the session bus
    var conn = try plume.Connection.init(io, allocator, .Session, init.environ_map);
    defer conn.close();

    // ... use the connection
}
```

### Calling a Method

You can use the `Proxy` to interact with remote objects.

```zig
const std = @import("std");
const plume = @import("plume");
const Proxy = plume.Proxy;
const GStr = plume.Value.GStr;

// Initialize a proxy for a specific object and interface
const p = Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

// Call a method (e.g., ListNames)
var result = try p.call("ListNames", .{});
defer result.deinit();

// Parse the result
// (Note: Implementation details for parsing specific complex return types may vary)
```

### Handling Signals

Register a callback function to handle specific signals.

```zig
fn onSignal(_: ?*anyopaque, msg: plume.core.Message) void {
    std.debug.print("Received signal!\n", .{});
}

// ... inside main
try conn.addMatch("type='signal',interface='dev.myinterface.test'");
try conn.registerSignalHandler("dev.myinterface.test", "MySignal", onSignal, null);
```

### Exporting an Object

Define a struct to represent your D-Bus interface and register it on the connection.

```zig
const std = @import("std");
const plume = @import("plume");

// Define the Interface
const MyInterface = struct {
    conn: *plume.Connection,

    // Properties (exposed via org.freedesktop.DBus.Properties)
    Count: plume.dbus_types.Property(i32, .ReadWrite) = plume.property(i32, .ReadWrite, 0),

    // Signals
    Tick: plume.dbus_types.Signal(i32) = plume.signal("Tick", i32),

    pub fn init(conn: *plume.Connection, _: void) @This() {
        return .{ .conn = conn };
    }

    // Methods are automatically exported
    pub fn Increment(self: *MyInterface) !i32 {
        self.Count.value += 1;
        // Trigger signal
        try self.Tick.trigger(self.conn, self.Count.value);
        return self.Count.value;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var conn = try plume.Connection.init(io, allocator, .Session, init.environ_map);
    defer conn.close();

    // Register Object: (Interface Type, Bus Name, Object Path)
    const handle = try conn.registerObject(
        MyInterface,
        "com.example.MyService",
        "/com/example/MyObject",
        {}, // user data passed into the object init call
    );

    // Serve requests
    try conn.waitOnHandle(handle);
}
```

## Tools

plume includes helper tools for introspection and code generation.
To use these tools in your own project, you must explicitly install them as
artifacts in your `build.zig`:

```zig
const plume_dep = b.dependency("plume", .{
    .target = target,
    .optimize = optimize,
});

b.installArtifact(plume_dep.artifact("plume-introspection"));
b.installArtifact(plume_dep.artifact("plume-generate"));
```

### Introspector

A tool to introspect a D-Bus object and output its XML definition.

```bash
./zig-out/bin/plume-introspection <destination> <path> <bus_type>
```

### Proxy Generator

Generate type-safe Zig bindings from D-Bus introspection XML.

```bash
./zig-out/bin/plume-generate <destination> <path> <bus_type>
```


[^1]: SASL (Simple Authentication and Security Layer) is used here to implement the `EXTERNAL` mechanism, which leverages Unix domain socket credentials for authentication.