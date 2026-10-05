# plume Wiki & API Reference

Welcome to the **plume** documentation. This guide covers the library architecture, connection lifecycle, type marshaling, client proxies, server exports, concurrency backends, and command-line tools for **Zig 0.17**.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Connection Management](#connection-management)
   - [Bus Types](#bus-types)
   - [Initialization & Cleanup](#initialization--cleanup)
   - [Concurrency Backends](#concurrency-backends)
   - [Connection API Reference](#connection-api-reference)
3. [Type System & Serialization](#type-system--serialization)
   - [Type Mappings](#type-mappings)
   - [D-Bus Value Wrappers](#d-bus-value-wrappers)
   - [Encoder & Decoder](#encoder--decoder)
   - [Properties & Signals](#properties--signals)
4. [Building D-Bus Services (Server)](#building-d-bus-services-server)
   - [Exporting a Struct](#exporting-a-struct)
   - [Methods, Properties & Signals](#methods-properties--signals)
   - [Serving Requests](#serving-requests)
5. [Client Proxies](#client-proxies)
   - [Proxy Initialization](#proxy-initialization)
   - [Calling Methods (`MethodResult`)](#calling-methods-methodresult)
   - [Reading & Writing Properties](#reading--writing-properties)
   - [Subscribing to Signals](#subscribing-to-signals)
6. [Command-Line Tools](#command-line-tools)
   - [plume-introspection](#plume-introspection)
   - [plume-generate](#plume-generate)

---

## Architecture Overview

`plume` is a lightweight, pure-Zig D-Bus implementation designed without any external C dependencies (no `libdbus`, no `GDBus`/GLib).

It provides complete coverage of the D-Bus specification:
- **Unix Domain Socket transport** with SASL EXTERNAL authentication.
- **Header & wire marshaling** conforming to the D-Bus binary protocol specification.
- **Compile-time reflection** mapping Zig types to D-Bus signatures.
- **Automatic introspection generator & dispatcher** for D-Bus server objects.
- **Dynamic & static client proxy generation**.

---

## Connection Management

### Bus Types

D-Bus connections support three standard bus categories defined in `Connection.BusType`:
- `.Session` – User session bus (resolved via `$DBUS_SESSION_BUS_ADDRESS`).
- `.System` – System-wide message bus (default `/var/run/dbus/system_bus_socket`).
- `.Accessibility` – Accessibility bus (resolved via session bus or a11y address).

### Initialization & Cleanup

In Zig 0.17, process arguments and environment variables are accessed via `std.process.Init`. `Connection.init` takes `init.io`, the allocator, the bus type, and the environment map:

```zig
const std = @import("std");
const plume = @import("plume");
const Connection = plume.Connection;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Connect to the session bus
    var conn: Connection = try .init(init.io, allocator, .Session, init.environ_map);
    defer conn.close();

    // Use connection...
}
```

### Concurrency Backends

`plume` supports two operational modes via `Connection.Backend`:

1. **`.threaded` (Default)**:
   - Automatically manages background worker and dispatch threads.
   - Incoming signals and method replies are queued and processed asynchronously.
   - Safe for high-concurrency multi-threaded method invocations.
   - Main loops use `try conn.serve()`, which parks cleanly on an OS futex until `conn.close()` is called.

2. **`.poll` (Single-Threaded)**:
   - Does **not** spawn background threads.
   - Ideal for single-threaded CLI apps, game loops, or event-loop integrations (`epoll`/`poll`/`io_uring`).
   - Created with `Connection.initWithBackend`:
     ```zig
     var conn: Connection = try .initWithBackend(init.io, allocator, .Session, init.environ_map, .poll);
     defer conn.close();

     const fd = conn.getFd();
     // In your event loop when fd is readable:
     _ = try conn.pollDispatch();
     ```

### Connection API Reference

| Method | Description |
|---|---|
| `init(io, allocator, bus_type, environ_map) !Connection` | Connects and authenticates over the specified bus. |
| `initWithBackend(io, allocator, bus_type, environ_map, backend) !Connection` | Connects with an explicit concurrency backend (`.threaded` or `.poll`). |
| `close() void` | Closes the socket, terminates background threads, and frees allocated structures. |
| `requestName(name: [:0]const u8) !void` | Requests a well-known bus name (e.g. `org.example.App`). |
| `registerObject(comptime T, bus_name, path, userData) !void` | Registers a struct `T` as a D-Bus object at `path` on `bus_name`. |
| `serve() !void` | Runs the main server loop (blocks until connection is closed). |
| `addMatch(match_rule: [:0]const u8) !void` | Adds a D-Bus routing match rule (e.g. `type='signal',interface='...'`). |
| `registerSignalHandler(iface, member, callback, ctx) !void` | Registers a callback for matching signals. |
| `methodCall(dest, path, iface, member, signature?, body) !Message` | Performs a synchronous method call and returns a reply `Message`. |
| `methodCallWithFds(dest, path, iface, member, signature?, body, fds) !Message` | Performs a synchronous method call passing file descriptors. |
| `sendReply(m, encoder) !void` | Sends a reply to a method call. |
| `sendReplyWithFds(m, encoder, fds) !void` | Sends a reply to a method call passing file descriptors. |
| `sendError(m, error_name, error_msg) !void` | Sends an error reply to a method call. |
| `freeMessage(message: *Message) void` | Frees a message buffer and closes untaken attached file descriptors. |
| `getFd() i32` | Returns the underlying socket file descriptor (useful in `.poll` backend). |
| `pollDispatch() !bool` | Reads and dispatches pending messages without background threads. |

---

## Type System & Serialization

### Type Mappings

`plume` uses comptime type inspection to map Zig types to D-Bus signatures:

| Zig Type | D-Bus Type | Signature |
|---|---|---|
| `u8` | BYTE | `y` |
| `bool` | BOOLEAN | `b` |
| `i16` | INT16 | `n` |
| `u16` | UINT16 | `q` |
| `i32` | INT32 | `i` |
| `u32` | UINT32 | `u` |
| `i64` | INT64 | `x` |
| `u64` | UINT64 | `t` |
| `f64` | DOUBLE | `d` |
| `GStr` (`[:0]const u8`) | STRING | `s` |
| `GPath` | OBJECT_PATH | `o` |
| `GSig` | SIGNATURE | `g` |
| `GUFd` (`u32`) | UNIX_FD | `h` |
| `ResolvedFd` | UNIX_FD (Resolved OS FD) | `h` |
| `[]const T` / `Value.Array(T)` | ARRAY | `a...` |
| `struct { ... }` / `@Tuple(...)` | STRUCT | `(...)` |
| `std.StringHashMap(V)` | DICT | `a{sv}` / `a{s...}` |
| `std.AutoHashMap(K, V)` | DICT | `a{...}` |
| `GVariant` / `Value.Variant(T)` | VARIANT | `v` |

### D-Bus Value Wrappers

Located in `plume.Value`:
- **`GStr`**: D-Bus string wrapper. Use `GStr.new("hello")`.
- **`GPath`**: D-Bus object path wrapper. Use `GPath.new("/org/example/Path")`.
- **`GSig`**: D-Bus type signature wrapper. Use `GSig.new("s")`.
- **`GUFd`**: Unix file descriptor index wrapper. Use `GUFd.new(index)`.
- **`ResolvedFd`**: Resolved OS file descriptor (`.handle`) and D-Bus wire index (`.index`). Call `duplicate()` to obtain an independent `O_CLOEXEC` descriptor that outlives the method call.
- **`GVariant`**: Tagged union capable of holding arbitrary D-Bus primitive and container variants.

### Encoder & Decoder

Use `Encoder` and `Decoder` directly for low-level serialization:

```zig
const plume = @import("plume");
const Encoder = plume.Encoder;
const Decoder = plume.Decoder;
const GStr = plume.Value.GStr;

// Encoding a single value or tuple of values
var encoder: Encoder = try .encode(allocator, .{ GStr.new("test"), @as(u32, 123) });
defer encoder.deinit();

const body = encoder.body();
const signature = encoder.signature(); // "su"

// Decoding from an existing buffer or Message
var decoder: Decoder = .init(allocator, body, signature, .little);
const str = try decoder.decode(GStr);
const num = try decoder.decode(u32);

// Or decode directly from a reply Message:
var msg_dec: Decoder = .fromMessage(allocator, reply);
const res = try msg_dec.decode(GStr);
```

### Properties & Signals

Define properties and signals in service structs using `.init(...)` or helper functions:

```zig
const MyService = struct {
    conn: *Connection,

    // Read-write property of type i32 with initial value 42
    count: plume.Property(i32, .ReadWrite) = .init(42),

    // Read-only property
    version: plume.Property(plume.Value.GStr, .Read) = .init(plume.Value.GStr.new("1.0.0")),

    // Signal definition with payload type GStr
    updated_signal: plume.Signal(plume.Value.GStr) = .init("Updated"),
};

// Triggering a signal from a service:
try self.updated_signal.trigger(self.conn, plume.Value.GStr.new("data"));
```

---

## Building D-Bus Services (Server)

### Exporting a Struct

Any Zig struct can be exported as a full-featured D-Bus object:
1. Provide a `conn: *Connection` field (or `connection: *Connection`).
2. Implement `pub fn init(conn: *Connection, userData: anytype) @This()`.
3. Provide an optional `pub const INTERFACE_NAME = "org.example.MyService";` declaration.
4. Export public methods and properties.

`plume` automatically handles:
- Routing incoming method calls by name.
- Automatic parameter injection: methods can optionally accept `*Connection` and/or `Message` / `*const Message` parameters (e.g. `pub fn MyMethod(self: *MyService, msg: plume.Message, x: i32) !void`). Injected parameters are omitted from the introspection XML and signature verification.
- Error handling: any error returned from an exported method is automatically converted to an `org.freedesktop.DBus.Error.Failed` reply.
- Memory management: slices passed as arguments are automatically cleaned up when the method invocation finishes.
- Standard `org.freedesktop.DBus.Properties` interface (`Get`, `Set`, `GetAll`).
- Standard `org.freedesktop.DBus.Introspectable` XML generation.

### Complete Server Example

```zig
const std = @import("std");
const plume = @import("plume");
const Connection = plume.Connection;
const GStr = plume.Value.GStr;

const CalcService = struct {
    conn: *Connection,
    Total: plume.Property(i64, .ReadWrite) = plume.property(i64, .ReadWrite, 0),
    CalculationDone: plume.Signal(i64) = plume.signal("CalculationDone", i64),

    pub const INTERFACE_NAME = "org.example.Calculator";

    pub fn init(conn: *Connection, _: void) @This() {
        return .{ .conn = conn };
    }

    // Method: Add(a: i64, b: i64) -> i64
    pub fn Add(self: *CalcService, a: i64, b: i64) !i64 {
        const sum = a + b;
        self.Total.value += sum;
        try self.CalculationDone.trigger(self.conn, sum);
        return sum;
    }

    // Method: Reset() -> void
    pub fn Reset(self: *CalcService) void {
        self.Total.value = 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var conn: Connection = try .init(init.io, allocator, .Session, init.environ_map);
    defer conn.close();

    try conn.registerObject(CalcService, "org.example.Calculator", "/org/example/Calculator", {});

    std.debug.print("Calculator service registered. Serving requests...\n", .{});
    try conn.serve();
}
```

---

## Client Proxies

The `Proxy` type encapsulates interaction with remote D-Bus objects, handling marshaling, invocation, response verification, property access, and signal subscriptions.

### Proxy Initialization

```zig
const plume = @import("plume");
const Proxy = plume.Proxy;

const p: Proxy = .init(
    &conn,
    "org.freedesktop.DBus",        // Destination / Bus name
    "/org/freedesktop/DBus",       // Object path
    "org.freedesktop.DBus",        // Default interface name
);
```

### Calling Methods (`MethodResult`)

Invoke methods using `.call(method_name, tuple_of_args)`:

```zig
var res = try p.call("NameHasOwner", .{ plume.Value.GStr.new("org.freedesktop.DBus") });
defer res.deinit();

// Expect a specific return type:
const has_owner = try res.expect(bool);
```

For return types containing allocated memory (such as arrays, slices, or hashmaps):
- `res.expect(T)`: Borrows slices and strings directly from the message buffer (valid until `res.deinit()`).
- `res.expectAlloc(T)`: Allocates owned copies of returned items using the connection allocator.

### Reading & Writing Properties

Read and write properties via `org.freedesktop.DBus.Properties`:

```zig
// Read a property
const PropType = union(enum) { string: plume.Value.GStr, int: i32 };
const val = try p.getProperty(PropType, "SomeProperty");

// Write a property
try p.setProperty("SomeProperty", @as(i32, 100));
```

### Subscribing to Signals

Register type-safe callbacks for remote signals:

```zig
fn onSignal(ctx: *u32, args: @Tuple(&[_]type{plume.Value.GStr})) void {
    ctx.* += 1;
    std.debug.print("Signal received: {s}\n", .{args[0].s});
}

var counter: u32 = 0;
try p.connectSignal(@Tuple(&[_]type{plume.Value.GStr}), "MySignalName", &counter, onSignal);
```

---

## Command-Line Tools

`plume` provides two tools installed under `zig-out/bin/`:

### plume-introspection

Inspects an existing object on the bus and prints its interfaces, methods, signals, and properties:

```bash
./zig-out/bin/plume-introspection <destination> <object_path> <bus_type>
```

**Example:**
```bash
./zig-out/bin/plume-introspection org.freedesktop.DBus /org/freedesktop/DBus Session
```

Output:
```text
Target: org.freedesktop.DBus /org/freedesktop/DBus
Found 6 interfaces.

Interface: org.freedesktop.DBus
  Method: Hello(s)
  Method: RequestName(s, u, u)
  Method: ListNames(as)
  ...
```

### plume-generate

Introspects an object and generates idiomatic, compile-ready Zig client proxy code:

```bash
./zig-out/bin/plume-generate <destination> <object_path> <bus_type>
```

**Example:**
```bash
./zig-out/bin/plume-generate org.freedesktop.UPower /org/freedesktop/UPower System > upower_proxy.zig
```

The resulting file contains typed structs with `.init()`, method wrappers (`.call(...)`), typed `.connectSignal(...)` helpers, and property accessors ready to import into your Zig application.
