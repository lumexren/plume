## Architecture

plume is a lightweight, pure-Zig alternative to `libdbus` or `GDBus`. It implements the entire D-Bus stack: socket communication, SASL EXTERNAL authentication, type marshaling, method dispatch, introspection, and code generation.

### Bus Connection

The `Connection` struct manages a Unix Domain Socket and performs the SASL EXTERNAL authentication handshake. It buffers stream data and runs a blocking message loop that routes incoming signals and method replies to registered handlers.

**Bus types**: `Session`, `System`, `Accessibility`.

```zig
const plume = @import("plume");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Connect to the session bus (bus_type can be .Session, .System, .Accessibility)
    var conn = try plume.Connection.init(io, allocator, &init.environ_map, .Session);
    defer conn.close();

    // ... use the connection
}
```

**Key Connection methods**:
- `init(io, allocator, map, bus_type)` – initializes socket, performs SASL EXTERNAL auth, returns a `Connection` or error.
- `close()` – frees buffers, closes the socket, destroys registered interfaces and signal handlers.
- `requestName(name)` – request a well‑known bus name.
- `sendMessage(msg)` – send a raw D‑Bus message.
- `registerObject(T, bus_name, path, userData)` – register a Zig struct as a D‑Bus object; returns a handle (`usize`) for the main loop.
- `waitOnHandle(handle)` – blocks, dispatching method calls, signals, and introspection requests for the given registered object.
- `addMatch(match)` – register a D‑Bus match rule (e.g. `type='signal',interface='dev.myinterface.test'`).
- `methodCall(dest, path, iface, member, sig?, body)` – perform a synchronous method call, returns a `Message`.
- `freeMessage(msg)` – free a message allocated by the library.
- `registerSignalHandler(interface, member, callback, ctx)` – register a callback for a specific signal.
- `waitMessage()` – blocks until a message is received; signals matching registered handlers are dispatched and not returned.

### Type System

plume uses compile‑time reflection to map Zig types to D‑Bus signatures. The `Value` module provides factory types and wrappers:

- **Basic numeric/boolean types**: `Int16`, `Uint16`, `Int32`, `Uint32`, `Int64`, `Uint64`, `Double`, `Byte`, `Bool`, `UnixFd`.
- **String‑like types**: `String` (`'s'`), `ObjectPath` (`'o'`), `Signature` (`'g'`).
- **Containers**: `Array`, `Tuple`, `Dict`, `Variant`, `Struct`.
- **Utility functions**: `dbusAlignOf`, `reprLength`, `getRepr`, `doesImplementSer`, `isDict`.

Wrappers for D‑Bus specific concepts:
- `GStr` – UTF‑8 string (`'s'`).
- `GPath` – D‑Bus object path (`'o'`).
- `GSig` – D‑Bus signature (`'g'`).
- `GUFd` – Unix file descriptor (`'h'`).
- `GVariant` – dynamic variant union type.

The `dbus_types` module provides high‑level helpers for properties and signals:

```zig
const plume = @import("plume");

// Property with read‑write access, default 0
const MyProp = plume.property(i32, .ReadWrite, 0);

// Signal definition
const MySignal = plume.signal("Tick", i32);
```

### Method Dispatcher

A Zig struct can be exported as a D‑Bus object. The library analyses public methods and fields to set up automatic routing. It also generates introspection XML and exposes the standard `org.freedesktop.DBus.Properties` interface.

A registered interface struct must provide:
- `pub fn init(conn: *Connection, userData: anytype) @This()` – called by `registerObject`.
- Public methods with signatures `pub fn method(self: *T, ...) !ReturnType`.
- Optional `pub const INTERFACE_NAME = "..."` (defaults to the registered bus name).
- Signal fields using `plume.signal("name", PayloadType)`.
- Property fields using `plume.property(Type, Access, value)`.

```zig
const MyInterface = struct {
    conn: *plume.Connection,
    Count: plume.dbus_types.Property(i32, .ReadWrite) = plume.property(i32, .ReadWrite, 0),
    Tick: plume.dbus_types.Signal(i32) = plume.signal("Tick", i32),

    pub fn init(conn: *plume.Connection, _: void) @This() {
        return .{ .conn = conn };
    }

    pub fn Increment(self: *MyInterface) !i32 {
        self.Count.value += 1;
        try self.Tick.trigger(self.conn, self.Count.value);
        return self.Count.value;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var conn = try plume.Connection.init(io, allocator, &init.environ_map, .Session);
    defer conn.close();

    const handle = try conn.registerObject(
        MyInterface,
        "com.example.MyService",
        "/com/example/MyObject",
        {}, // user data passed into init
    );

    try conn.waitOnHandle(handle);
}
```

### Client Proxies

The `Proxy` abstraction simplifies client‑side interactions by handling construction of method call messages and parsing of replies.

```zig
const plume = @import("plume");
const Proxy = plume.Proxy;
const GStr = plume.Value.GStr;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var conn = try plume.Connection.init(io, allocator, &init.environ_map, .Session);
    defer conn.close();

    // Connect to a remote object
    const p = Proxy.init(&conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus");

    // Call a method – returns a MethodResult owning the reply message
    var result = try p.call("ListNames", .{});
    defer result.deinit();

    // Parse the reply (e.g. expect a specific type)
    // var names = try result.expect([]const u8); // or use decoders

    // Get a property
    // var value = try p.getProperty(SomeType, "SomeProperty");

    // Subscribe to a signal
    // p.connectSignal(SomeSignalArgs, "SignalName", .{}, fn(ctx, args) { ... });
}
```

**Proxy API**:
- `Proxy.init(connection, destination, path, interface)` – create a proxy.
- `rawCall(interface, method, args)` – low‑level call, returns `!MethodResult`.
- `call(method, args)` – convenience, forwards to `rawCall` using the default interface.
- `getProperty(comptime T, name)` – read a property; `T` must be a variant type.
- `setProperty(name, value)` – write a property.
- `connectSignal(comptime SignalArgs, member, ctx, callback)` – register a typed signal handler.

**MethodResult**:
- `deinit()` – free the owned message.
- `expect(comptime T)` – borrow‑style decode (may allocate internally).
- `expectAlloc(comptime T)` – deep‑copy decode.

### Tools

plume ships two binaries that are installed as artifacts in `build.zig`.

#### Introspector

```bash
./zig-out/bin/plume-introspection <destination> <path> <bus_type>
```
Example:
```bash
./zig-out/bin/plume-introspection org.freedesktop.DBus /org/freedesktop/DBus Session
```
Connects to the bus, calls `Introspect` on the target, parses the XML and prints all interfaces, methods and signals.

#### Proxy Generator

```bash
./zig-out/bin/plume-generate <destination> <path> <bus_type>
```
Example:
```bash
./zig-out/bin/plume-generate org.freedesktop.DBus /org/freedesktop/DBus Session
```
Connects to the bus, introspects the object, and emits complete Zig proxy source code (structs with `call`, `connectSignal`, `getProperty`, `setProperty`) to stdout.

Both are installed via `b.installArtifact(plume_dep.artifact("plume-introspection"))` and `b.installArtifact(plume_dep.artifact("plume-generate"))` in `build.zig`.