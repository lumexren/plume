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

const Connection = @This();

const Decoder = @import("Decoder.zig");
const Encoder = @import("Encoder.zig");
const Value = @import("Value.zig");
const GStr = Value.GStr;
const GPath = Value.GPath;
const GSig = Value.GSig;
const GUFd = Value.GUFd;
const DBusWriter = @import("DBusWriter.zig");
const Message = @import("Message.zig");
const MessageHeader = Message.MessageHeader;
const MessageType = Message.MessageType;
const MessageFlag = Message.MessageFlag;
const HeaderField = Message.HeaderField;
const HeaderFieldCode = Message.HeaderFieldCode;
const HeaderFieldValue = Message.HeaderFieldValue;
const SocketIterator = @import("SocketIterator.zig");

const std = @import("std");
const lang = std.lang;
const Endian = lang.Endian;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Io = std.Io;
const Reader = Io.Reader;
const net = Io.net;
const os = std.os;
const fmt = std.fmt;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;
const mem = std.mem;
const Allocator = mem.Allocator;
const debug = std.debug;
const meta = std.meta;

const common = @import("common.zig");
const dispatcher = @import("dispatcher.zig");
const xml_generator = @import("xml_generator.zig");

/// Specifies the type of D-Bus connection.
pub const BusType = enum {
    /// The session bus (user-specific).
    Session,
    /// The system bus.
    System,
    /// The accessibility bus (AT-SPI).
    Accessibility,
};

const RequestNameFlags = enum(u32) {
    None = 0,
    AllowReplacement = 1,
    ReplaceExisting = 2,
    DoNotQueue = 4,
};

/// Represents a connection to a D-Bus bus (session or system).
/// Manages message sending, receiving, and object registration.
io: Io,
stream: net.Stream,
allocator: Allocator,
reader_buffer: []u8,
reader: net.Stream.Reader,
serial_counter: u32 = 1,
pending_messages: ArrayList(Message),
signal_handlers: ArrayList(common.SignalHandler),
registered_interfaces: ArrayList(common.InterfaceWrapper),

/// Initializes a new connection to the D-Bus bus.
/// `bus_type`: The type of bus to connect to (.Session, .System, or .Accessibility).
/// `io`: Mandatory [`std.Io`]
/// `map`: Environment variables provided from the entry point
pub fn init(io: Io, allocator: Allocator, map: *Map, bus_type: BusType) !Connection {
    var socket_paths: SocketIterator = undefined;
    var unix_addr: net.UnixAddress = undefined;
    var allocated_path: ?[]u8 = null;
    defer if (allocated_path) |p| allocator.free(p);

    switch (bus_type) {
        .Session => {
            const bus_address = map.get("DBUS_SESSION_BUS_ADDRESS") orelse return error.EnvVarNotFound;
            socket_paths = .init(bus_address);
        },
        .System => {
            if (map.get("DBUS_SYSTEM_BUS_ADDRESS")) |addr| {
                socket_paths = .init(addr);
            } else {
                socket_paths = .init("unix:path=/var/run/dbus/system_bus_socket");
            }
        },
        .Accessibility => {
            if (map.get("AT_SPI_BUS_ADDRESS")) |addr| {
                socket_paths = .init(addr);
            } else {
                const uid = os.linux.getuid();
                allocated_path = try fmt.allocPrint(allocator, "unix:path=/run/user/{d}/at-spi/bus_0", .{uid});
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
        .stream = socket,
        .allocator = allocator,
        .reader_buffer = reader_buf,
        .io = io,
        .pending_messages = try .initCapacity(allocator, 10),
        .signal_handlers = try .initCapacity(allocator, 0),
        .registered_interfaces = try .initCapacity(allocator, 0),
        .reader = socket.reader(io, reader_buf),
    };

    try connection.auth();
    try connection.sayHello();

    return connection;
}

fn auth(this: *Connection) !void {
    var io_reader = &this.reader.interface;

    var writer_buffer: [2048]u8 = undefined;
    var writer = this.stream.writer(this.io, &writer_buffer);
    var io_writer = &writer.interface;

    const uid: u32 = os.linux.getuid();
    var uid_buf: [32]u8 = undefined;
    const uid_str = try fmt.bufPrint(&uid_buf, "{}", .{uid});

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
    if (!mem.startsWith(u8, response, "OK")) {
        return error.HandshakeFail;
    }

    try io_writer.print("BEGIN\r\n", .{});
    try io_writer.flush();
}

fn sayHello(this: *Connection) !void {
    const serial = this.serial_counter;
    defer this.serial_counter += 1;

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = @intFromEnum(MessageFlag.__EMPTY),
        .proto_version = 1,
        .body_length = 0,
        .serial = serial,
        .header_fields = @constCast(&[_]HeaderField{
            .{ .code = HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
            .{ .code = HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
            .{ .code = HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
            .{ .code = HeaderFieldCode.Member, .value = .{ .Member = "Hello" } },
        }),
    };

    const body: ArrayList(u8) = .empty;

    const message: Message = .new(header, body.items);

    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    var response = try this.call(bytes.items, serial);
    defer this.freeMessage(&response);
}

/// This function closes the underlined socket
pub fn close(this: *Connection) void {
    for (this.pending_messages.items) |*message| {
        this.freeMessage(message);
    }

    this.pending_messages.deinit(this.allocator);
    this.signal_handlers.deinit(this.allocator);

    for (this.registered_interfaces.items) |*wrapper| {
        wrapper.destroy(wrapper, this.allocator);
    }

    this.registered_interfaces.deinit(this.allocator);

    this.allocator.free(this.reader_buffer);
    this.stream.close(this.io);
}

/// Requests a well-known name on the bus.
pub fn requestName(this: *Connection, name: [:0]const u8) !void {
    const Str = Value.String();
    const U32 = Value.Uint32();

    const serial = this.serial_counter;
    defer this.serial_counter += 1;

    var body_arr: ArrayList(u8) = try .initCapacity(this.allocator, 256);
    defer body_arr.deinit(this.allocator);

    var dwriter: DBusWriter = .init(this.allocator, &body_arr, .little);

    const flags = @intFromEnum(RequestNameFlags.DoNotQueue) | @intFromEnum(RequestNameFlags.ReplaceExisting);

    try Str.new(name).ser(&dwriter);
    try U32.new(flags).ser(&dwriter);

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = flags,
        .proto_version = 1,
        .body_length = @intCast(body_arr.items.len),
        .serial = serial,
        .header_fields = @constCast(&[_]HeaderField{
            .{ .code = HeaderFieldCode.Destination, .value = .{ .Destination = "org.freedesktop.DBus" } },
            .{ .code = HeaderFieldCode.Interface, .value = .{ .Interface = "org.freedesktop.DBus" } },
            .{ .code = HeaderFieldCode.Path, .value = .{ .Path = "/org/freedesktop/DBus" } },
            .{ .code = HeaderFieldCode.Member, .value = .{ .Member = "RequestName" } },
            .{ .code = HeaderFieldCode.Signature, .value = .{ .Signature = "su" } },
        }),
    };

    const message: Message = .new(header, body_arr.items);

    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    var response = try this.call(bytes.items, serial);
    defer this.freeMessage(&response);

    if (response.header.message_type == .Error) {
        for (response.header.header_fields) |f| {
            if (f.code == .ErrorName) {
                debug.print("[plume] RequestName failed with ErrorName: {s}\n", .{f.value.ErrorName});
            }
        }
    }
}

/// Sends a D-Bus message over the connection.
pub fn sendMessage(this: *Connection, message: Message) !void {
    var bytes = try message.pack(this.allocator);
    defer bytes.deinit(this.allocator);

    var writer_buffer: [2048]u8 = undefined;
    var writer_stream = this.stream.writer(this.io, &writer_buffer);
    var writer = &writer_stream.interface;

    try writer.writeAll(bytes.items);
    try writer.flush();
}

/// Registers an object (interface implementation) at a specific path.
/// The struct T must have an `init` method.
/// `bus_name`: The well-known name to request on the bus.
/// `path`: The object path to export this interface at.
pub fn registerObject(this: *Connection, comptime T: type, bus_name: [:0]const u8, path: [:0]const u8, userData: anytype) !usize {
    try this.requestName(bus_name);

    const interface_name = if (@hasDecl(T, "INTERFACE_NAME")) T.INTERFACE_NAME else if (@hasDecl(T, "REQUESTED_NAME")) T.REQUESTED_NAME else bus_name;

    // Instantiate
    var instance_ptr = try this.allocator.create(T);
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

    // Create wrapper
    const wrapper: common.InterfaceWrapper = .{
        .instance = @ptrCast(instance_ptr),
        .interface_name = interface_name,
        .path = path,
        .intro_xml = intro_xml,
        .destroy = struct {
            fn destroy(w: *const common.InterfaceWrapper, allocator: Allocator) void {
                const this_ptr = @as(*T, @ptrCast(@alignCast(w.instance)));
                allocator.destroy(this_ptr);
                allocator.free(w.intro_xml);
            }
        }.destroy,
        .dispatch = dispatcher.getDispatchFn(T),
    };

    errdefer {
        this.allocator.destroy(instance_ptr);
        this.allocator.free(intro_xml);
    }

    try this.registered_interfaces.append(this.allocator, wrapper);

    return this.registered_interfaces.items.len - 1;
}

/// Sends a reply to a method call.
pub fn sendReply(this: *Connection, message: Message, enc: Encoder) !void {
    var reply_fields: ArrayList(HeaderField) = try .initCapacity(this.allocator, 3);

    defer {
        for (reply_fields.items) |f| {
            switch (f.value) {
                .Destination, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        reply_fields.deinit(this.allocator);
    }

    try reply_fields.append(this.allocator, .{ .code = .ReplySerial, .value = .{ .ReplySerial = message.header.serial } });

    var dst: ?[:0]const u8 = null;
    for (message.header.header_fields) |f| if (f.code == .Sender) {
        dst = f.value.Sender;
    };

    if (dst) |d| {
        const dest_dup = try this.allocator.dupeSentinel(u8, d, 0);
        errdefer this.allocator.free(dest_dup);
        try reply_fields.append(this.allocator, .{ .code = .Destination, .value = .{ .Destination = dest_dup } });
    } else {
        debug.print("WARN: No Sender in request, reply has no Destination!\n", .{});
    }

    const sig_dup = try this.allocator.dupeSentinel(u8, enc.signature(), 0);
    errdefer this.allocator.free(sig_dup);
    try reply_fields.append(this.allocator, .{ .code = .Signature, .value = .{ .Signature = sig_dup } });

    const reply_h: MessageHeader = .{
        .message_type = .MethodReturn,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(enc.body().len),
        .serial = this.serial_counter,
        .header_fields = reply_fields.items,
    };

    this.serial_counter += 1;

    try this.sendMessage(Message.new(reply_h, enc.body()));
}

/// Sends an Error reply to a message.
pub fn sendError(this: *Connection, m: Message, error_name: [:0]const u8, error_msg: [:0]const u8) !void {
    var reply_fields: ArrayList(HeaderField) = try .initCapacity(this.allocator, 4);

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
        debug.print("WARN: No Sender in request, error reply has no Destination!\n", .{});
    }

    var encoder: Encoder = try .encode(this.allocator, GStr.new(error_msg));
    defer encoder.deinit();

    try reply_fields.append(this.allocator, .{ .code = .Signature, .value = .{ .Signature = try this.allocator.dupeSentinel(u8, encoder.signature(), 0) } });

    const reply_h: MessageHeader = .{
        .message_type = .Error,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(encoder.body().len),
        .serial = this.serial_counter,
        .header_fields = reply_fields.items,
    };

    this.serial_counter += 1;

    try this.sendMessage(Message.new(reply_h, encoder.body()));
}

/// Runs the main loop, blocking and handling messages for the registered objects.
pub fn waitOnHandle(this: *Connection, handle: usize) !void {
    if (handle >= this.registered_interfaces.items.len) return error.InvalidHandle;

    while (true) {
        var msg = try this.waitMessage();
        defer this.freeMessage(&msg);

        if (msg.header.message_type == .MethodCall) {
            // Check interface and path
            var iface: ?[]const u8 = null;
            var path: ?[]const u8 = null;
            var member: ?[]const u8 = null;
            for (msg.header.header_fields) |f| {
                if (f.code == .Interface) iface = f.value.Interface;
                if (f.code == .Path) path = f.value.Path;
                if (f.code == .Member) member = f.value.Member;
            }

            if (path) |p| {
                var handled = false;
                for (this.registered_interfaces.items) |*w| {
                    // Check path first
                    if (mem.eql(u8, w.path, p)) {
                        // Then check interface or Introspectable
                        if (iface) |i| {
                            if (mem.eql(u8, w.interface_name, i) or
                                mem.eql(u8, i, "org.freedesktop.DBus.Introspectable") or
                                mem.eql(u8, i, "org.freedesktop.DBus.Properties"))
                            {
                                // Dispatch
                                try w.dispatch(w, this, msg);
                                handled = true;
                            }
                        } else {
                            // Fallback dispatch
                            try w.dispatch(w, this, msg);
                            handled = true;
                        }
                    }
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

                            var encoder: Encoder = try .encode(this.allocator, GStr.new(xml_slice));
                            defer encoder.deinit();

                            try this.sendReply(msg, encoder);
                        }
                    }
                }
            }
        }
    }
}

/// Registers interest in specific signals or messages using a D-Bus match rule.
pub fn addMatch(this: *Connection, match: [:0]const u8) !void {
    var encoder: Encoder = try .encode(this.allocator, GStr.new(match));
    defer encoder.deinit();
    // We don't care about the return value usually for AddMatch
    var reply = try this.methodCall("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", encoder.signature(), encoder.body());
    this.freeMessage(&reply);
}

/// Performs a synchronous D-Bus method call.
pub fn methodCall(self: *Connection, dest: [:0]const u8, path: [:0]const u8, iface: [:0]const u8, member: [:0]const u8, signature: ?[:0]const u8, body: []const u8) !Message {
    const serial = self.serial_counter;
    defer self.serial_counter += 1;

    var fields_list: ArrayList(HeaderField) = try .initCapacity(self.allocator, 5);
    defer fields_list.deinit(self.allocator);

    try fields_list.append(self.allocator, .{ .code = .Destination, .value = .{ .Destination = dest } });
    try fields_list.append(self.allocator, .{ .code = .Path, .value = .{ .Path = path } });
    try fields_list.append(self.allocator, .{ .code = .Interface, .value = .{ .Interface = iface } });
    try fields_list.append(self.allocator, .{ .code = .Member, .value = .{ .Member = member } });

    if (signature) |sig| {
        try fields_list.append(self.allocator, .{ .code = .Signature, .value = .{ .Signature = sig } });
    }

    const header: MessageHeader = .{
        .message_type = .MethodCall,
        .flags = 0,
        .proto_version = 1,
        .body_length = @intCast(body.len),
        .serial = serial,
        .header_fields = fields_list.items,
    };

    const message: Message = .new(header, body);

    var bytes = try message.pack(self.allocator);
    defer bytes.deinit(self.allocator);

    return self.call(bytes.items, serial);
}

/// Frees resources associated with a message.
pub fn freeMessage(this: *Connection, message: *Message) void {
    this.allocator.free(message.body);

    for (message.header.header_fields) |f| {
        switch (f.value) {
            .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| this.allocator.free(s),
            else => {},
        }
    }

    this.allocator.free(message.header.header_fields);
}

/// Registers a callback for a specific D-Bus signal.
pub fn registerSignalHandler(this: *Connection, interface: []const u8, member: []const u8, callback: *const fn (ctx: ?*anyopaque, msg: Message) void, ctx: ?*anyopaque) !void {
    try this.signal_handlers.append(this.allocator, .{
        .interface = interface,
        .member = member,
        .callback = callback,
        .ctx = ctx,
    });
}

/// Blocks until a message is received and returns it.
/// Signals that match a registered handler will be dispatched automatically and NOT returned.
pub fn waitMessage(this: *Connection) !Message {
    while (true) {
        const message = if (this.pending_messages.items.len > 0)
            this.pending_messages.orderedRemove(0)
        else
            try this.readNextMessage();

        if (message.header.message_type == .Signal) {
            var dispatched = false;
            for (this.signal_handlers.items) |handler| {
                if (message.isSignal(handler.interface, handler.member)) {
                    handler.callback(handler.ctx, message);
                    dispatched = true;
                }
            }

            if (dispatched) {
                this.freeMessage(@constCast(&message));
                continue;
            }
        }

        return message;
    }
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

    const mtype: MessageType = @enumFromInt(header_buf[1]);
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
    if (padding > 0) {
        try io_reader.discardAll(padding);
    }

    // Read body
    const body = try this.allocator.alloc(u8, body_len);
    errdefer this.allocator.free(body);

    try io_reader.readSliceAll(body);

    // Parse fields
    var fields_list: ArrayList(HeaderField) = try .initCapacity(this.allocator, 4);
    errdefer {
        for (fields_list.items) |f| {
            switch (f.value) {
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }

        fields_list.deinit(this.allocator);
    }

    var freader: Reader = .fixed(fields_bytes);

    while (freader.seek < fields_len) {
        const padding_f = (8 - (freader.seek % 8)) % 8;
        if (padding_f > 0) {
            try freader.discardAll(padding_f);
        }
        if (freader.seek >= fields_len) break;

        const code_u8 = try freader.takeByte();
        const code: HeaderFieldCode = if (code_u8 <= 9) @enumFromInt(code_u8) else .Invalid;

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

                const hfv: HeaderFieldValue = switch (c) {
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
                debug.print("WARN: Unknown Header Field Code {d}\n", .{code_u8});
                return error.UnknownHeaderField;
            },
        }
    }

    const final_fields = try fields_list.toOwnedSlice(this.allocator);
    errdefer {
        for (final_fields) |f| {
            switch (f.value) {
                .Path, .Interface, .Member, .ErrorName, .Destination, .Sender, .Signature => |s| this.allocator.free(s),
                else => {},
            }
        }
        this.allocator.free(final_fields);
    }

    return .{
        .header = .{
            .endianess = endian,
            .message_type = mtype,
            .flags = flags,
            .proto_version = version,
            .body_length = body_len,
            .serial = msg_serial,
            .header_fields = final_fields,
        },
        .body = body,
    };
}

fn printData(data: []u8) void {
    for (data) |x| {
        if ((x >= 46 and x <= 57) or (x >= 65 and x <= 90) or (x >= 97 and x <= 122)) {
            debug.print("{c}", .{x});
        } else {
            debug.print("\\{o}", .{x});
        }
    }
    debug.print("\n", .{});
}

fn call(this: *Connection, data: []u8, serial: u32) !Message {
    var writer_buffer: [2048]u8 = undefined;
    var writer_stream = this.stream.writer(this.io, &writer_buffer);
    var writer = &writer_stream.interface;

    try writer.writeAll(data);
    try writer.flush();

    while (true) {
        // Check pending messages first
        for (this.pending_messages.items, 0..) |*message, i| {
            if (message.header.message_type == .MethodReturn or message.header.message_type == .Error) {
                for (message.header.header_fields) |f| {
                    if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                        const found = this.pending_messages.orderedRemove(i);
                        return found;
                    }
                }
            }
        }

        // Read new message
        const message = try this.readNextMessage();

        // Check if it is the reply
        var is_reply = false;
        if (message.header.message_type == .MethodReturn or message.header.message_type == .Error) {
            for (message.header.header_fields) |f| {
                if (f.code == .ReplySerial and f.value.ReplySerial == serial) {
                    is_reply = true;
                    break;
                }
            }
        }

        if (is_reply) {
            return message;
        } else {
            if (message.header.message_type == .Signal) {
                var dispatched = false;
                for (this.signal_handlers.items) |handler| {
                    if (message.isSignal(handler.interface, handler.member)) {
                        handler.callback(handler.ctx, message);
                        dispatched = true;
                    }
                }

                if (dispatched) {
                    this.freeMessage(@constCast(&message));
                    continue;
                }
            }

            try this.pending_messages.append(this.allocator, message);
        }
    }
}
