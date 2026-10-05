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

/// Represents a connection to a D-Bus bus (session or system).
/// Manages message sending, receiving, and object registration.
const Connection = @This();

const Message = @import("Message.zig");
const MessageQueue = @import("MessageQueue.zig");
const MessageHeader = Message.MessageHeader;
const MessageType = MessageHeader.MessageType;
const MessageFlag = MessageHeader.MessageFlag;
const MessageHeaderField = MessageHeader.HeaderField;
const MessageHeaderFieldCode = MessageHeader.HeaderFieldCode;
const MessageHeaderFieldValue = MessageHeader.HeaderFieldValue;
const MessageHeaderFieldValueTag = MessageHeader.HeaderFieldValueTag;
const InterfaceWrapper = @import("InterfaceWrapper.zig");
const SocketIterator = @import("SocketIterator.zig");
const SignalHandler = @import("SignalHandler.zig");
const Value = @import("value/Value.zig");
const DBusWriter = Value.DBusWriter;
const Encoder = @import("Encoder.zig");

const xml_generator = @import("xml_generator.zig");
const dispatcher = @import("dispatcher.zig");

const std = @import("std");
const AutoHashMap = std.AutoHashMap;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const Thread = std.Thread;
const Endian = std.lang.Endian;
const os = std.os;
const linux = os.linux;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;
const math = std.math;
const Io = std.Io;
const net = Io.net;
const Mutex = Io.Mutex;
const atomic = std.atomic;
const posix = std.posix;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const CallState = enum(u32) {
    pending = 0,
    completed = 1,
    err = 2,
};

pub const PendingCall = struct {
    state: atomic.Value(u32) = .init(@backingInt(CallState.pending)),
    reply: ?Message = null,
};

pub fn MutexMap(comptime K: type, comptime V: type) type {
    return struct {
        map: AutoHashMap(K, V),
        mutex: Mutex = .init,
        io: Io,

        pub fn init(io: Io, allocator: Allocator) @This() {
            return .{ .map = .init(allocator), .io = io };
        }

        pub fn deinit(this: *@This()) void {
            this.mutex.lockUncancelable(this.io);
            defer this.mutex.unlock(this.io);
            this.map.deinit();
        }

        pub fn put(this: *@This(), key: K, value: V) !void {
            this.mutex.lockUncancelable(this.io);
            defer this.mutex.unlock(this.io);
            try this.map.put(key, value);
        }

        pub fn get(this: *@This(), key: K) ?V {
            this.mutex.lockUncancelable(this.io);
            defer this.mutex.unlock(this.io);
            return this.map.get(key);
        }

        pub fn remove(this: *@This(), key: K) bool {
            this.mutex.lockUncancelable(this.io);
            defer this.mutex.unlock(this.io);
            return this.map.remove(key);
        }

        pub fn wakeAllWithError(this: *@This()) void {
            this.mutex.lockUncancelable(this.io);
            defer this.mutex.unlock(this.io);
            var it = this.map.valueIterator();
            while (it.next()) |pending_ptr| {
                pending_ptr.*.state.store(@backingInt(CallState.err), .release);
                this.io.futexWake(u32, &pending_ptr.*.state.raw, 1);
            }
        }
    };
}

/// Defines the concurrency/event-loop model for the connection.
pub const Backend = enum {
    threaded,
    poll,
};

/// Specifies the type of D-Bus connection.
pub const BusType = enum {
    /// The session bus (user-specific).
    Session,
    /// The system bus.
    System,
    /// The accessibility bus (AT-SPI).
    Accessibility,
};
pub const SocketReader = @import("SocketReader.zig");

backend: Backend = .threaded,
supports_unix_fd: bool = false,
io: Io,
socket: net.Stream,
allocator: Allocator,
reader_buffer: []u8,
reader: SocketReader,
serial_counter: atomic.Value(u32) = .init(1),
write_mutex: Mutex = .init,
pending_calls: MutexMap(u32, *PendingCall),
dispatch_queue: MessageQueue,
worker_init_mutex: Mutex = .init,
worker_thread: ?Thread = null,
dispatch_thread: ?Thread = null,
is_running: atomic.Value(bool),
serve_futex: atomic.Value(u32),
is_initialized: bool = false,
signal_handlers_mutex: Mutex = .init,
signal_handlers: ArrayList(SignalHandler),
registered_interfaces: ArrayList(InterfaceWrapper),

pub fn nextSerial(this: *Connection) u32 {
    return this.serial_counter.fetchAdd(1, .monotonic);
}

/// Returns the underlying socket file descriptor for integration with external event loops.
pub fn getFd(this: *const Connection) posix.fd_t {
    return this.socket.socket.handle;
}

/// Checks if there is pending data to read, either buffered in user-space or ready in the kernel socket.
pub fn hasDataToRead(this: *Connection) bool {
    if (this.reader.interface.end > this.reader.interface.seek) return true;

    var pfd = [1]posix.pollfd{.{
        .fd = this.getFd(),
        .events = posix.POLL.IN,
        .revents = 0,
    }};

    const n = posix.poll(&pfd, 0) catch return false;
    return n > 0 and (pfd[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0;
}

/// Dispatches a single pending message if available without blocking.
/// Returns true if a message was dispatched, false if no data was available.
pub fn dispatch(this: *Connection) !bool {
    if (!this.hasDataToRead()) return false;

    const msg = try this.readNextMessage();
    if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
        var reply_serial: ?u32 = null;
        for (msg.header.header_fields) |f| {
            if (f.code == .ReplySerial) {
                reply_serial = f.value.ReplySerial;
                break;
            }
        }

        if (reply_serial) |serial| {
            if (this.pending_calls.get(serial)) |pending| {
                pending.reply = msg;
                pending.state.store(@backingInt(CallState.completed), .release);
                this.io.futexWake(u32, &pending.state.raw, 1);
                return true;
            }
        }

        this.freeMessage(@constCast(&msg));

        return true;
    }

    try this.dispatchUnsolicited(msg);

    return true;
}

fn sendmsgWithFds(this: *Connection, bytes: []const u8, fds: []const posix.fd_t) !void {
    var iov = [1]posix.iovec_const{.{
        .base = bytes.ptr,
        .len = bytes.len,
    }};

    const MaxFds = 32;
    if (fds.len > MaxFds) return error.TooManyFileDescriptors;

    const cmsg_align = @alignOf(usize);
    const cmsg_hdr_len = comptime mem.alignForward(usize, @sizeOf(std.c.cmsghdr), cmsg_align);
    const total_cmsg = cmsg_hdr_len + fds.len * @sizeOf(posix.fd_t);

    const CmsgSpace = comptime cmsg_hdr_len + mem.alignForward(usize, MaxFds * @sizeOf(posix.fd_t), cmsg_align);
    var cmsg_buf: [CmsgSpace]u8 align(@alignOf(std.c.cmsghdr)) = undefined;

    const cmsg: *std.c.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len = @intCast(total_cmsg);
    cmsg.level = posix.SOL.SOCKET;
    cmsg.type = posix.SCM.RIGHTS;

    const fds_dest: [*]posix.fd_t = @ptrCast(@alignCast(&cmsg_buf[cmsg_hdr_len]));
    for (fds, 0..) |f, i| {
        fds_dest[i] = f;
    }

    var msg = posix.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = total_cmsg,
        .flags = 0,
    };

    var sent_total: usize = 0;
    while (sent_total < bytes.len) {
        if (sent_total > 0) {
            msg.control = null;
            msg.controllen = 0;
        }
        iov[0].base = bytes.ptr + sent_total;
        iov[0].len = bytes.len - sent_total;

        const rc = posix.system.sendmsg(this.getFd(), &msg, 0);
        const err = posix.errno(rc);
        if (err != .SUCCESS) {
            if (err == .INTR) continue;
            if (err == .AGAIN) continue;
            return error.WriteFailed;
        }
        sent_total += @intCast(rc);
    }
}

fn writeMessageBytesWithFds(this: *Connection, bytes: []const u8, fds: []const posix.fd_t) !void {
    this.write_mutex.lockUncancelable(this.io);
    defer this.write_mutex.unlock(this.io);

    if (fds.len > 0) {
        try this.sendmsgWithFds(bytes, fds);
    } else {
        var writer_buffer: [2048]u8 = undefined;
        var writer = this.socket.writer(this.io, &writer_buffer);
        var io_writer = &writer.interface;

        try io_writer.writeAll(bytes);
        try io_writer.flush();
    }
}

fn writeMessageBytes(this: *Connection, bytes: []const u8) !void {
    try this.writeMessageBytesWithFds(bytes, &.{});
}

fn auth(this: *Connection) !void {
    var io_reader = &this.reader.interface;

    var writer_buffer: [2048]u8 = undefined;
    var writer = this.socket.writer(this.io, &writer_buffer);
    var io_writer = &writer.interface;

    const uid: u32 = linux.getuid();
    var uid_buf: [32]u8 = undefined;
    const uid_str = try mem.print(&uid_buf, "{}", .{uid});

    var hex_buf: [64]u8 = undefined;
    var out_i: usize = 0;
    for (uid_str) |ch| {
        const hi = "0123456789ABCDEF"[(ch >> 4) & 0xF];
        const lo = "0123456789ABCDEF"[ch & 0xF];
        hex_buf[out_i] = hi;
        hex_buf[out_i + 1] = lo;
        out_i += 2;
    }

    const hex = hex_buf[0..out_i];

    try io_writer.writeByte(0);
    try io_writer.print("AUTH EXTERNAL {s}\r\n", .{hex});
    try io_writer.flush();

    const response = try io_reader.takeDelimiterInclusive('\n');
    if (!mem.startsWith(u8, response, "OK")) return error.HandshakeFail;

    try io_writer.print("NEGOTIATE_UNIX_FD\r\n", .{});
    try io_writer.flush();

    const fd_response = try io_reader.takeDelimiterInclusive('\n');
    if (mem.startsWith(u8, fd_response, "AGREE_UNIX_FD")) {
        this.supports_unix_fd = true;
    } else {
        this.supports_unix_fd = false;
    }

    try io_writer.print("BEGIN\r\n", .{});
    try io_writer.flush();
}

/// Initializes a new connection to the D-Bus bus using the default threaded backend.
/// `bus_type`: The type of bus to connect to (.Session, .System, or .Accessibility).
/// `io`: Mandatory [`Io`]
/// `vars`: Environment variables provided from the entry point
pub fn init(io: Io, allocator: Allocator, bus_type: BusType, vars: *Map) !Connection {
    return initWithBackend(io, allocator, bus_type, vars, .threaded);
}

/// Initializes a new connection to the D-Bus bus with the specified backend (.threaded or .poll).
pub fn initWithBackend(io: Io, allocator: Allocator, bus_type: BusType, vars: *Map, backend: Backend) !Connection {
    var socket_paths: SocketIterator = undefined;
    var unix_addr: net.UnixAddress = undefined;
    var allocated_path: ?[]u8 = null;
    defer if (allocated_path) |p| allocator.free(p);

    switch (bus_type) {
        .Session => {
            const bus_address = vars.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.EnvVarNotFound;
            socket_paths = .init(bus_address);
        },
        .System => {
            if (vars.get("DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
                socket_paths = .init(addr);
            } else {
                socket_paths = .init("unix:path=/var/run/dbus/system_bus_socket");
            }
        },
        .Accessibility => {
            if (vars.get("AT_SPI_BUS_ADDRESS")) |addr| {
                socket_paths = .init(addr);
            } else {
                const uid = linux.getuid();
                allocated_path = try allocator.print("unix:path=/run/user/{d}/at-spi/bus_0", .{uid});
                socket_paths = .init(allocated_path.?);
            }
        },
    }

    while (socket_paths.next()) |path| {
        unix_addr = net.UnixAddress.init(path) catch continue;
        break;
    } else {
        return error.NoValidAddressFound;
    }

    const reader_buf = try allocator.alloc(u8, 4096 * 10);
    errdefer allocator.free(reader_buf);

    const socket = try unix_addr.connect(io);

    var connection: Connection = .{
        .backend = backend,
        .socket = socket,
        .allocator = allocator,
        .reader_buffer = reader_buf,
        .io = io,
        .serial_counter = .init(1),
        .write_mutex = .init,
        .pending_calls = .init(io, allocator),
        .dispatch_queue = .init(io, allocator),
        .worker_init_mutex = .init,
        .worker_thread = null,
        .dispatch_thread = null,
        .is_running = .init(false),
        .serve_futex = .init(0),
        .signal_handlers = try .initCapacity(allocator, 0),
        .registered_interfaces = try .initCapacity(allocator, 0),
        .reader = try SocketReader.init(socket.socket.handle, allocator, io, reader_buf),
    };

    try connection.auth();

    connection.sayHello() catch |err| {
        connection.close();
        return err;
    };

    connection.is_initialized = true;
    connection.is_running.store(true, .release);

    return connection;
}

fn sayHello(this: *Connection) !void {
    const serial = this.nextSerial();

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = @backingInt(MessageFlag.__EMPTY),
        .proto_version = 1,
        .body_length = 0,
        .serial = serial,
        .header_fields = @constCast(&[_]MessageHeaderField{
            .{ .code = .Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
            .{ .code = .Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
            .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
            .{ .code = .Member, .value = .{ .Member = "Hello" } },
        }),
    };

    const body: ArrayList(u8) = .empty;

    const message: Message = .new(header, body.items);

    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    var response = try this.call(bytes.items, serial);
    defer this.freeMessage(&response);
}

/// This function closes the underlying socket and terminates background threads.
pub fn close(this: *Connection) void {
    this.is_running.store(false, .release);
    this.dispatch_queue.wakeAll();

    this.socket.shutdown(this.io, .recv) catch {};
    this.socket.close(this.io);

    if (this.worker_thread) |thread| {
        thread.join();
        this.worker_thread = null;
    }

    if (this.dispatch_thread) |thread| {
        thread.join();
        this.dispatch_thread = null;
    }

    this.serve_futex.store(1, .release);
    this.io.futexWake(u32, &this.serve_futex.raw, math.maxInt(u32));

    this.pending_calls.wakeAllWithError();
    this.pending_calls.deinit();
    this.dispatch_queue.deinit(this);

    this.signal_handlers.deinit(this.allocator);

    for (this.registered_interfaces.items) |*wrapper| wrapper.destroy(wrapper, this.allocator);

    this.registered_interfaces.deinit(this.allocator);

    this.reader.deinit();
    this.allocator.free(this.reader_buffer);
}

const RequestNameFlags = enum(u32) {
    None = 0,
    AllowReplacement = 1,
    ReplaceExisting = 2,
    DoNotQueue = 4,
};

/// Requests a well-known name on the bus.
pub fn requestName(this: *Connection, name: [:0]const u8) !void {
    const Str = Value.String();
    const U32 = Value.Uint32();

    const serial = this.nextSerial();

    var body_arr: ArrayList(u8) = try .initCapacity(this.allocator, 256);
    defer body_arr.deinit(this.allocator);

    var dwriter: DBusWriter = .init(this.allocator, &body_arr, .little);

    const flags =
        @backingInt(RequestNameFlags.DoNotQueue) |
        @backingInt(RequestNameFlags.ReplaceExisting);

    try Str.new(name).ser(&dwriter);
    try U32.new(flags).ser(&dwriter);

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(body_arr.items.len),
        .serial = serial,
        .header_fields = @constCast(&[_]MessageHeaderField{
            .{ .code = .Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
            .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
            .{ .code = .Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
            .{ .code = .Member, .value = .{ .Member = "RequestName" } },
            .{ .code = .Signature, .value = .{ .Signature = "su" } },
        }),
    };

    const message: Message = .new(header, body_arr.items);

    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    var response = try this.call(bytes.items, serial);
    defer this.freeMessage(&response);

    if (response.header.message_type == .Error) {
        for (response.header.header_fields) |f| {
            if (f.code == .ErrorName) std.debug.print("[plume] RequestName failed with ErrorName: {s}\n", .{f.value.ErrorName});
        }
        return error.RequestNameFailed;
    }
}

/// Sends a D-Bus message over the connection.
pub fn sendMessage(this: *Connection, message: Message) !void {
    var msg_to_pack = message;
    var header_fields_copy: ?ArrayList(MessageHeaderField) = null;
    defer if (header_fields_copy) |*hfc| hfc.deinit(this.allocator);

    if (message.fds.len > 0) {
        var has_unix_fds = false;
        for (message.header.header_fields) |f| {
            if (f.code == .UnixFds) {
                has_unix_fds = true;
                break;
            }
        }
        if (!has_unix_fds) {
            var fields = try ArrayList(MessageHeaderField).initCapacity(this.allocator, message.header.header_fields.len + 1);
            try fields.appendSlice(this.allocator, message.header.header_fields);
            try fields.append(this.allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(message.fds.len) } });
            msg_to_pack.header.header_fields = fields.items;
            header_fields_copy = fields;
        }
    }

    var bytes = try msg_to_pack.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    try this.writeMessageBytesWithFds(bytes.items, message.fds);
}

/// Registers an object (interface implementation) at a specific path.
/// The struct T must have an `init` method.
/// `bus_name`: The well-known name to request on the bus.
/// `path`: The object path to export this interface at.
pub fn registerObject(this: *Connection, comptime T: type, bus_name: [:0]const u8, path: [:0]const u8, userData: anytype) !void {
    try this.requestName(bus_name);

    const interface_name = if (@hasDecl(T, "INTERFACE_NAME")) T.INTERFACE_NAME else if (@hasDecl(T, "REQUESTED_NAME")) T.REQUESTED_NAME else bus_name;

    // Instantiate
    var instance_ptr = try this.allocator.create(T);
    errdefer this.allocator.destroy(instance_ptr);
    // We assume init signature: fn init(conn: *Connection, userData: anytype) T
    instance_ptr.* = T.init(this, userData);

    // Bind signals
    // We iterate over fields. If a field is a Signal, we set its interface and path.
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |field_name, FieldType| {
        if (@typeInfo(FieldType) == .@"struct" and @hasDecl(FieldType, "__is_plume_signal")) {
            const sig = &@field(instance_ptr, field_name);
            sig.interface = interface_name;
            sig.path = path;
        }
    }

    // Generate Introspection XML
    const intro_xml = try xml_generator.generateIntrospectionXml(this.allocator, T, interface_name);
    errdefer this.allocator.free(intro_xml);

    // Create wrapper
    const wrapper: InterfaceWrapper = .{
        .instance = @ptrCast(instance_ptr),
        .interface_name = interface_name,
        .path = path,
        .intro_xml = intro_xml,
        .destroy = struct {
            fn destroy(w: *const InterfaceWrapper, allocator: Allocator) void {
                const self_ptr = @as(*T, @ptrCast(@alignCast(w.instance)));
                allocator.destroy(self_ptr);
                allocator.free(w.intro_xml);
            }
        }.destroy,
        .dispatch = dispatcher.getDispatchFn(T),
    };

    try this.registered_interfaces.append(this.allocator, wrapper);
}

/// Sends a reply to a method call.
pub fn sendReply(this: *Connection, m: Message, encoder: Encoder) !void {
    var reply_fields: ArrayList(MessageHeaderField) = try .initCapacity(this.allocator, 3);
    defer {
        for (reply_fields.items) |f| {
            switch (f.value) {
                .Destination, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        reply_fields.deinit(this.allocator);
    }

    try reply_fields.append(this.allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });

    var dst: ?[:0]const u8 = null;
    for (m.header.header_fields) |f| if (f.code == .Sender) {
        dst = f.value.Sender;
    };

    if (dst) |d| {
        try reply_fields.append(this.allocator, .{ .code = .Destination, .value = .{ .Destination = try this.allocator.dupeSentinel(u8, d, 0) } });
    } else {
        std.debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
    }

    try reply_fields.append(this.allocator, .{
        .code = .Signature,
        .value = .{
            .Signature = try this.allocator.dupeSentinel(u8, encoder.signature(), 0),
        },
    });

    const serial = this.nextSerial();
    const reply_h: MessageHeader = .{
        .message_type = .MethodReturn,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(encoder.body().len),
        .serial = serial,
        .header_fields = reply_fields.items,
    };

    try this.sendMessage(Message.new(reply_h, encoder.body()));
}

/// Sends a reply to a method call passing file descriptors.
pub fn sendReplyWithFds(this: *Connection, m: Message, encoder: Encoder, fds: []const posix.fd_t) !void {
    var reply_fields: ArrayList(MessageHeaderField) = try .initCapacity(this.allocator, 4);
    defer {
        for (reply_fields.items) |f| {
            switch (f.value) {
                .Destination, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        reply_fields.deinit(this.allocator);
    }

    try reply_fields.append(this.allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });

    var dst: ?[:0]const u8 = null;
    for (m.header.header_fields) |f| if (f.code == .Sender) {
        dst = f.value.Sender;
    };

    if (dst) |d| {
        try reply_fields.append(this.allocator, .{ .code = .Destination, .value = .{ .Destination = try this.allocator.dupeSentinel(u8, d, 0) } });
    } else {
        std.debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
    }

    try reply_fields.append(this.allocator, .{
        .code = .Signature,
        .value = .{
            .Signature = try this.allocator.dupeSentinel(u8, encoder.signature(), 0),
        },
    });

    if (fds.len > 0) {
        try reply_fields.append(this.allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(fds.len) } });
    }

    const serial = this.nextSerial();
    const reply_h: MessageHeader = .{
        .message_type = .MethodReturn,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(encoder.body().len),
        .serial = serial,
        .header_fields = reply_fields.items,
    };

    try this.sendMessage(Message.newWithFds(reply_h, encoder.body(), fds));
}

/// Sends an Error reply to a message.
pub fn sendError(this: *Connection, m: Message, error_name: [:0]const u8, error_msg: [:0]const u8) !void {
    var reply_fields: ArrayList(MessageHeaderField) = try .initCapacity(this.allocator, 4);
    defer {
        for (reply_fields.items) |f| {
            switch (f.value) {
                .Destination, .ErrorName, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        reply_fields.deinit(this.allocator);
    }

    try reply_fields.append(this.allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = m.header.serial } });
    try reply_fields.append(this.allocator, .{ .code = .ErrorName, .value = .{ .ErrorName = try this.allocator.dupeSentinel(u8, error_name, 0) } });

    var dst: ?[:0]const u8 = null;
    for (m.header.header_fields) |f| if (f.code == .Sender) {
        dst = f.value.Sender;
    };

    if (dst) |d| {
        try reply_fields.append(this.allocator, .{ .code = .Destination, .value = .{ .Destination = try this.allocator.dupeSentinel(u8, d, 0) } });
    } else {
        std.debug.print("WARN: No Sender in request, error reply has no Destination!\n", .{});
    }

    var encoder: Encoder = try .encode(this.allocator, Value.GStr.new(error_msg));
    defer encoder.deinit();

    try reply_fields.append(this.allocator, .{
        .code = .Signature,
        .value = .{
            .Signature = try this.allocator.dupeSentinel(u8, encoder.signature(), 0),
        },
    });

    const serial = this.nextSerial();
    const reply_h: MessageHeader = .{
        .message_type = .Error,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(encoder.body().len),
        .serial = serial,
        .header_fields = reply_fields.items,
    };

    try this.sendMessage(Message.new(reply_h, encoder.body()));
}

pub fn ensureWorkersStarted(this: *Connection) !void {
    if (this.backend != .threaded) return;
    if (this.worker_thread != null) return;
    this.worker_init_mutex.lockUncancelable(this.io);
    defer this.worker_init_mutex.unlock(this.io);
    if (this.worker_thread == null) {
        this.is_running.store(true, .release);
        const dt = try Thread.spawn(.{}, dispatchLoop, .{this});
        errdefer {
            this.is_running.store(false, .release);
            this.dispatch_queue.wakeAll();
            dt.join();
        }

        this.dispatch_thread = dt;

        const wt = try Thread.spawn(.{}, workerLoop, .{this});
        this.worker_thread = wt;
    }
}

fn dispatchLoop(this: *Connection) void {
    while (this.is_running.load(.acquire)) {
        const message = this.dispatch_queue.popOrWait(&this.is_running) orelse break;
        this.dispatchUnsolicited(message) catch {};
    }
}

/// Runs the main loop, sleeping securely while background threads handle messages.
pub fn serve(this: *Connection) !void {
    if (this.backend == .poll) return error.InvalidBackend;
    if (this.is_initialized) try this.ensureWorkersStarted();

    this.serve_futex.store(0, .release);
    while (this.is_running.load(.acquire)) this.io.futexWaitUncancelable(u32, &this.serve_futex.raw, 0);
}

fn dispatchUnsolicited(this: *Connection, message: Message) !void {
    defer this.freeMessage(@constCast(&message));

    if (message.header.message_type == .Signal) {
        this.signal_handlers_mutex.lockUncancelable(this.io);
        defer this.signal_handlers_mutex.unlock(this.io);

        for (this.signal_handlers.items) |handler| {
            if (message.isSignal(handler.interface, handler.member)) handler.callback(handler.ctx, message);
        }

        return;
    }

    if (message.header.message_type == .MethodCall) {
        // Check interface and path
        var iface: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var member: ?[]const u8 = null;
        for (message.header.header_fields) |f| {
            if (f.code == .Interface) iface = f.value.Interface;
            if (f.code == .Path) path = f.value.Path;
            if (f.code == .Member) member = f.value.Member;
        }

        if (path) |p| {
            var handled = false;
            var intro_interfaces: ArrayList(u8) = .empty;
            defer intro_interfaces.deinit(this.allocator);

            for (this.registered_interfaces.items) |*w| {
                // Check path first
                if (mem.eql(u8, w.path, p)) {
                    // Then check interface or Introspectable
                    if (iface) |i| {
                        if (mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") and member != null and mem.eql(u8, member.?, "Introspect")) {
                            // Introspection needs a little special handling, because there may be multiple
                            // interfaces implemented by the object, and we have to return all of them.

                            // Begin the XML if this is the first interface
                            if (intro_interfaces.items.len == 0) try intro_interfaces.appendSlice(this.allocator, xml_generator.xml_prelude);

                            try intro_interfaces.appendSlice(this.allocator, w.intro_xml);
                        } else if (mem.eql(u8, w.interface_name, i) or mem.eql(u8, i, "org.freedesktop.DBus.Properties")) {
                            // Dispatch
                            const dispatch_result = try w.dispatch(w, this, message);
                            handled = dispatch_result == .dispatched;
                        }
                    } else {
                        // Fallback dispatch
                        const dispatch_result = try w.dispatch(w, this, message);
                        handled = dispatch_result == .dispatched;
                    }
                }
            }

            // Handle static introspection
            if (intro_interfaces.items.len != 0) {
                // Wrap up the XML
                try intro_interfaces.appendSlice(this.allocator, xml_generator.xml_postlude);
                const xml = try intro_interfaces.toOwnedSliceSentinel(this.allocator, 0);
                defer this.allocator.free(xml);

                var encoder: Encoder = try .encode(this.allocator, Value.GStr.new(xml));
                defer encoder.deinit();

                try this.sendReply(message, encoder);
                handled = true;
            }

            // Handle GetAll when no interfaces match
            if (!handled and iface != null and mem.eql(u8, iface.?, "org.freedesktop.DBus.Properties") and member != null and mem.eql(u8, member.?, "GetAll")) {
                var dict: StringHashMap(Value.GVariant) = .init(this.allocator);
                defer dict.deinit();

                var encoder: Encoder = try .encode(this.allocator, dict);
                defer encoder.deinit();

                try this.sendReply(message, encoder);

                handled = true;
            }

            // Dynamic Introspection logic
            if (!handled) {
                if (member) |m| {
                    if (mem.eql(u8, m, "Introspect") and (iface == null or mem.eql(u8, iface.?, "org.freedesktop.DBus.Introspectable"))) {
                        // Check for children
                        var children_xml: ArrayList(u8) = try .initCapacity(this.allocator, 256);
                        defer children_xml.deinit(this.allocator);

                        // We need a set to avoid duplicates
                        var seen_children: StringHashMap(void) = .init(this.allocator);
                        defer seen_children.deinit();

                        for (this.registered_interfaces.items) |*w| {
                            if (mem.startsWith(u8, w.path, p)) {
                                if (w.path.len > p.len) {
                                    var child_name: []const u8 = "";
                                    if (mem.eql(u8, p, "/")) {
                                        // Special case root
                                        if (w.path.len > 1) {
                                            const sub = w.path[1..];
                                            if (mem.findScalar(u8, sub, '/')) |idx| {
                                                child_name = sub[0..idx];
                                            } else {
                                                child_name = sub;
                                            }
                                        }
                                    } else {
                                        // Check if w.path[p.len] == '/'
                                        if (w.path[p.len] == '/') {
                                            const sub = w.path[p.len + 1 ..];
                                            if (mem.findScalar(u8, sub, '/')) |idx| {
                                                child_name = sub[0..idx];
                                            } else {
                                                child_name = sub;
                                            }
                                        }
                                    }

                                    if (child_name.len > 0) {
                                        if (seen_children.get(child_name) == null) {
                                            try seen_children.put(child_name, {});
                                            try children_xml.print(this.allocator, "  <node name=\"{s}\"/>\n", .{child_name});
                                        }
                                    }
                                }
                            }
                        }

                        // Construct full XML
                        var full_xml: ArrayList(u8) = try .initCapacity(this.allocator, 1024);
                        defer full_xml.deinit(this.allocator);

                        try full_xml.appendSlice(this.allocator, "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"");
                        try full_xml.appendSlice(this.allocator, " \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n");
                        try full_xml.appendSlice(this.allocator, "<node>\n");
                        try full_xml.appendSlice(this.allocator, children_xml.items);
                        try full_xml.appendSlice(this.allocator, "</node>\n");

                        // Send Reply
                        const xml_slice = try full_xml.toOwnedSliceSentinel(this.allocator, 0);
                        defer this.allocator.free(xml_slice);

                        var encoder: Encoder = try .encode(this.allocator, Value.GStr.new(xml_slice));
                        defer encoder.deinit();

                        try this.sendReply(message, encoder);
                    }
                }
            }
        }
    }
}

/// Registers interest in specific signals or messages using a D-Bus match rule.
pub fn addMatch(this: *Connection, match: [:0]const u8) !void {
    var encoder: Encoder = try .encode(this.allocator, Value.GStr.new(match));
    defer encoder.deinit();
    // We don't care about the return value usually for AddMatch
    var reply = try this.methodCall("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", encoder.signature(), encoder.body());
    this.freeMessage(&reply);
}

/// Performs a synchronous D-Bus method call.
pub fn methodCall(this: *Connection, dest: [:0]const u8, path: [:0]const u8, iface: [:0]const u8, member: [:0]const u8, signature: ?[:0]const u8, body: []const u8) !Message {
    return this.methodCallWithFds(dest, path, iface, member, signature, body, &.{});
}

/// Performs a synchronous D-Bus method call passing file descriptors.
pub fn methodCallWithFds(
    this: *Connection,
    dest: [:0]const u8,
    path: [:0]const u8,
    iface: [:0]const u8,
    member: [:0]const u8,
    signature: ?[:0]const u8,
    body: []const u8,
    fds: []const posix.fd_t,
) !Message {
    const serial = this.nextSerial();

    var fields_list: ArrayList(MessageHeaderField) = try .initCapacity(this.allocator, 6);
    defer fields_list.deinit(this.allocator);

    try fields_list.append(this.allocator, .{ .code = .Destination, .value = .{ .Destination = dest } });
    try fields_list.append(this.allocator, .{ .code = .Path, .value = .{ .Path = path } });
    try fields_list.append(this.allocator, .{ .code = .Interface, .value = .{ .Interface = iface } });
    try fields_list.append(this.allocator, .{ .code = .Member, .value = .{ .Member = member } });

    if (signature) |sig| try fields_list.append(this.allocator, .{ .code = .Signature, .value = .{ .Signature = sig } });
    if (fds.len > 0) try fields_list.append(this.allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = @intCast(fds.len) } });

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(body.len),
        .serial = serial,
        .header_fields = fields_list.items,
    };

    const message: Message = .newWithFds(header, body, fds);

    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    return this.callWithFds(bytes.items, serial, fds);
}

/// Frees resources associated with a message.
pub fn freeMessage(this: *Connection, message: *Message) void {
    this.allocator.free(message.body);

    for (message.header.header_fields) |f| {
        switch (f.value) {
            .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| {
                this.allocator.free(s);
            },
            else => {},
        }
    }

    this.allocator.free(message.header.header_fields);

    if (message.allocator != null) {
        for (message.fds) |fd| {
            if (fd >= 0) {
                _ = posix.system.close(fd);
            }
        }
        if (message.fds.len > 0) {
            this.allocator.free(message.fds);
        }
    }
    message.fds = &.{};
}

/// Registers a callback for a specific D-Bus signal.
pub fn registerSignalHandler(this: *Connection, interface: []const u8, member: []const u8, callback: *const fn (ctx: ?*anyopaque, message: Message) void, ctx: ?*anyopaque) !void {
    this.signal_handlers_mutex.lockUncancelable(this.io);
    defer this.signal_handlers_mutex.unlock(this.io);

    try this.signal_handlers.append(this.allocator, .{
        .interface = interface,
        .member = member,
        .callback = callback,
        .ctx = ctx,
    });
}

fn workerLoop(this: *Connection) void {
    while (this.is_running.load(.acquire)) {
        const msg = this.readNextMessage() catch |err| {
            if (!this.is_running.load(.acquire)) break;
            std.debug.print("workerLoop read error: {}\n", .{err});
            break;
        };

        if (msg.header.message_type == .MethodReturn or msg.header.message_type == .Error) {
            var reply_serial: ?u32 = null;
            for (msg.header.header_fields) |f| {
                if (f.code == .ReplySerial) {
                    reply_serial = f.value.ReplySerial;
                    break;
                }
            }

            if (reply_serial) |serial| {
                if (this.pending_calls.get(serial)) |pending| {
                    pending.reply = msg;
                    pending.state.store(@backingInt(CallState.completed), .release);
                    this.io.futexWake(u32, &pending.state.raw, 1);
                } else {
                    this.freeMessage(@constCast(&msg));
                }
            } else {
                this.freeMessage(@constCast(&msg));
            }
        } else {
            this.dispatch_queue.push(msg) catch |push_err| {
                std.debug.print("workerLoop push error: {}\n", .{push_err});
                this.freeMessage(@constCast(&msg));
            };
        }
    }

    this.is_running.store(false, .release);
    this.pending_calls.wakeAllWithError();
    this.dispatch_queue.wakeAll();
    this.serve_futex.store(1, .release);
    this.io.futexWake(u32, &this.serve_futex.raw, math.maxInt(u32));
}

fn readNextMessage(this: *Connection) !Message {
    var header_buf: [16]u8 = undefined;

    var io_reader = &this.reader.interface;
    try io_reader.readSliceAll(&header_buf);

    const endian: Endian = switch (header_buf[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.BadEndianFlag,
    };

    const mtype: MessageType = @fromBackingInt(@intCast(header_buf[1]));
    const flags = header_buf[2];
    const version = header_buf[3];
    const body_len = mem.readInt(u32, header_buf[4..8], endian);
    const msg_serial = mem.readInt(u32, header_buf[8..12], endian);
    const fields_len = mem.readInt(u32, header_buf[12..16], endian);

    const fields_bytes = try this.allocator.alloc(u8, fields_len);
    defer this.allocator.free(fields_bytes);
    try io_reader.readSliceAll(fields_bytes);

    // Align stream to 8 bytes
    const current_pos = 16 + fields_len;
    const padding = (8 - (current_pos % 8)) % 8;
    if (padding > 0) try io_reader.discardAll(padding);

    // Read body
    const body = try this.allocator.alloc(u8, body_len);
    errdefer this.allocator.free(body);
    try io_reader.readSliceAll(body);

    // Parse fields
    var fields_list: ArrayList(MessageHeaderField) = try .initCapacity(this.allocator, 4);
    errdefer {
        for (fields_list.items) |f| {
            switch (f.value) {
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        fields_list.deinit(this.allocator);
    }

    var freader: Io.Reader = .fixed(fields_bytes);

    while (freader.seek < fields_len) {
        const padding_f = (8 - (freader.seek % 8)) % 8;
        if (padding_f > 0) try freader.discardAll(padding_f);
        if (freader.seek >= fields_len) break;

        const code_u8 = try freader.takeByte();
        const code: MessageHeaderFieldCode = if (code_u8 <= 9) @fromBackingInt(@intCast(code_u8)) else .Invalid;

        // Variant signature (we assume standard fields have correct types)
        const sig_len = try freader.takeByte();
        try freader.discardAll(sig_len + 1); // sig + null

        switch (code) {
            .ReplySerial => {
                const pad4 = (4 - (freader.seek % 4)) % 4;
                try freader.discardAll(pad4);
                const val = try freader.takeInt(u32, endian);
                try fields_list.append(this.allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = val } });
            },
            .UnixFds => {
                const pad4 = (4 - (freader.seek % 4)) % 4;
                try freader.discardAll(pad4);
                const val = try freader.takeInt(u32, endian);
                try fields_list.append(this.allocator, .{ .code = .UnixFds, .value = .{ .UnixFds = val } });
            },
            .Signature => {
                const s_len = try freader.takeByte();
                const s_owned = try this.allocator.allocSentinel(u8, s_len, 0);
                try freader.readSliceAll(s_owned);
                try freader.discardAll(1); // null
                try fields_list.append(this.allocator, .{ .code = .Signature, .value = .{ .Signature = s_owned } });
            },
            .Path, .Interface, .Member, .ErrorName, .Destination, .Sender => |c| {
                const pad4 = (4 - (freader.seek % 4)) % 4;
                try freader.discardAll(pad4);
                const s_len = try freader.takeInt(u32, endian);
                const s_owned = try this.allocator.allocSentinel(u8, s_len, 0);
                try freader.readSliceAll(s_owned);
                try freader.discardAll(1); // null

                const hfv: MessageHeaderFieldValue = switch (c) {
                    .Path => .{ .Path = s_owned },
                    .Interface => .{ .Interface = s_owned },
                    .Member => .{ .Member = s_owned },
                    .ErrorName => .{ .ErrorName = s_owned },
                    .Destination => .{ .Destination = s_owned },
                    .Sender => .{ .Sender = s_owned },
                    else => unreachable,
                };

                try fields_list.append(this.allocator, .{ .code = c, .value = hfv });
            },
            else => {
                // Unknown field, cannot safely skip without parsing signature.
                // For now, assume it consumes nothing more or panic?
                // We risk desync here.
                std.debug.print("WARN: Unknown Header Field Code {d}\n", .{code_u8});
                return error.UnknownHeaderField;
            },
        }
    }

    var unix_fds_count: u32 = 0;
    for (fields_list.items) |f| {
        if (f.code == .UnixFds) {
            unix_fds_count = f.value.UnixFds;
            break;
        }
    }

    const header_fields = try fields_list.toOwnedSlice(this.allocator);
    errdefer this.allocator.free(header_fields);

    var msg_fds: []posix.fd_t = &.{};
    if (unix_fds_count > 0) {
        msg_fds = try this.allocator.alloc(posix.fd_t, unix_fds_count);
        var fds_taken: usize = 0;
        errdefer {
            for (msg_fds[0..fds_taken]) |fd| {
                _ = posix.system.close(fd);
            }
            this.allocator.free(msg_fds);
        }
        this.reader.mutex.lockUncancelable(this.io);
        defer this.reader.mutex.unlock(this.io);
        for (0..unix_fds_count) |i| {
            if (this.reader.received_fds.items.len > 0) {
                msg_fds[i] = this.reader.received_fds.orderedRemove(0);
                fds_taken += 1;
            } else {
                return error.MissingUnixFds;
            }
        }
    }

    return .{
        .allocator = this.allocator,
        .body = body,
        .fds = msg_fds,
        .header = .{
            .endianess = endian,
            .message_type = mtype,
            .flags = flags,
            .proto_version = version,
            .body_length = body_len,
            .serial = msg_serial,
            .header_fields = header_fields,
        },
    };
}

fn printData(data: []u8) void {
    for (data) |x| {
        if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
            std.debug.print("{c}", .{x});
        } else {
            std.debug.print("\\{o}", .{x});
        }
    }
    std.debug.print("\n", .{});
}

fn call(this: *Connection, data: []u8, serial: u32) !Message {
    return this.callWithFds(data, serial, &.{});
}

fn callWithFds(this: *Connection, data: []u8, serial: u32, fds: []const posix.fd_t) !Message {
    var pending = PendingCall{};

    try this.pending_calls.put(serial, &pending);
    defer _ = this.pending_calls.remove(serial);

    if (this.is_initialized) try this.ensureWorkersStarted();

    try this.writeMessageBytesWithFds(data, fds);

    if (this.backend == .poll or this.worker_thread == null) {
        while (true) {
            if (pending.reply) |r| return r;

            const message = try this.readNextMessage();
            if (message.header.message_type == .MethodReturn or message.header.message_type == .Error) {
                var reply_serial: ?u32 = null;
                for (message.header.header_fields) |f| {
                    if (f.code == .ReplySerial) {
                        reply_serial = f.value.ReplySerial;
                        break;
                    }
                }

                if (reply_serial != null and reply_serial.? == serial) return message;
                if (reply_serial) |rserial| {
                    if (this.pending_calls.get(rserial)) |p| {
                        p.reply = message;
                        p.state.store(@backingInt(CallState.completed), .release);
                        continue;
                    }
                }

                this.freeMessage(@constCast(&message));

                continue;
            }

            this.dispatchUnsolicited(message) catch {};
        }
    }

    while (pending.state.load(.acquire) == @backingInt(CallState.pending)) this.io.futexWaitUncancelable(u32, &pending.state.raw, @backingInt(CallState.pending));

    if (pending.state.load(.acquire) == @backingInt(CallState.err)) return error.ConnectionClosed;

    if (pending.reply) |r| {
        return r;
    } else {
        return error.CallFailed;
    }
}
