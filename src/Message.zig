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

/// Represents a D-Bus message, including its header and body.
const Message = @This();

const DBusWriter = @import("DBusWriter.zig");
const Value = @import("Value.zig");
const dbusAlignOf = Value.dbusAlignOf;

const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const lang = std.lang;
const Endian = lang.Endian;

pub const HeaderFieldValueTag = enum {
    /// The object to send a call to, or the object a signal is emitted from.
    /// The special path `/org/freedesktop/DBus/Local` is reserved; implementations
    /// should not send messages with this path, and the reference implementation
    /// of the bus daemon will disconnect any application that attempts to do so.
    /// This header field is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Path,
    ///  The interface to invoke a method call on, or that a signal is emitted from.
    ///  Optional for method calls, required for signals.
    ///  The special interface `org.freedesktop.DBus.Local` is reserved;
    ///  implementations should not send messages with this interface,
    ///  and the reference implementation of the bus daemon will disconnect any
    ///  application that attempts to do so. This header field is controlled by
    ///  the message sender.
    ///
    ///  **Required In**: Signal
    Interface,
    ///  The member, either the method name or signal name. This header field
    ///  is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Member,
    /// The name of the error that occurred, for errors
    ///
    /// **Required In**: `Error`
    ErrorName,
    ///  The serial number of the message this message is a reply to.
    ///  (The serial number is the second UINT32 in the header.)
    ///  This header field is controlled by the message sender.
    ///
    ///  **Required In**: `Error`, `MethodReturn`
    ReplySerial,
    ///  The name of the connection this message is intended for. This field is
    ///  usually only meaningful in combination with the message bus¹ but other
    ///  servers may define their own meanings for it. This header field is
    ///  controlled by the message sender.
    ///
    ///  ¹see [the section called "Message Bus Specification"](https://dbus.freedesktop.org/doc/dbus-specification.html#message-bus)
    ///
    /// **~optional**
    Destination,
    /// Unique name of the sending connection. This field is usually only
    /// meaningful in combination with the message bus, but other servers may
    /// define their own meanings for it. On a message bus, this header field
    /// is controlled by the message bus, so it is as reliable and trustworthy
    /// as the message bus itself. Otherwise, this header field is controlled
    /// by the message sender, unless there is out-of-band information that
    /// indicates otherwise.
    ///
    /// **~optional**
    Sender,
    /// The signature of the message body.
    /// If omitted, it is assumed to be the empty signature "" (i.e. the body must be 0-length).
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    Signature,
    /// The number of Unix file descriptors that accompany the message.
    /// If omitted, it is assumed that no Unix file descriptors accompany the message.
    /// The actual file descriptors need to be transferred via platform specific
    /// mechanism out-of-band. They must be sent at the same time as part of the
    /// message itself. They may not be sent before the first byte of the message
    /// itself is transferred or after the last byte of the message itself.
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    UnixFds,
};

/// A union representing the value of a D-Bus message header field.
pub const HeaderFieldValue = union(HeaderFieldValueTag) {
    Path: [:0]const u8,
    Interface: [:0]const u8,
    Member: [:0]const u8,
    ErrorName: [:0]const u8,
    ReplySerial: u32,
    Destination: [:0]const u8,
    Sender: [:0]const u8,
    Signature: [:0]const u8,
    UnixFds: u32,

    pub fn ser(this: @This(), w: *DBusWriter) !void {
        const Sig = Value.Signature();
        const Str = Value.String();
        const Path = Value.ObjectPath();
        const U32 = Value.Uint32();

        switch (this) {
            .UnixFds, .ReplySerial => |x| {
                try U32.new(x).ser(&w);
            },
            .Path => |v| {
                try Path.new(v).ser(&w);
            },
            .Interface, .Member, .ErrorName, .Destination, .Sender => |v| {
                try Str.new(v).ser(&w);
            },
            .Signature => |v| {
                try Sig.new(v).ser(&w);
            },
        }
    }
};

/// The type code for a D-Bus message header field.
pub const HeaderFieldCode = enum(u8) {
    Invalid = 0x0,
    Path = 0x1,
    Interface = 0x2,
    Member = 0x3,
    ErrorName = 0x4,
    ReplySerial = 0x5,
    Destination = 0x6,
    Sender = 0x7,
    Signature = 0x8,
    UnixFds = 0x9,
};

/// A D-Bus message header field consisting of a code and a value.
pub const HeaderField = struct {
    code: HeaderFieldCode,
    value: HeaderFieldValue,
};

pub const MessageFlag = enum(u8) {
    __EMPTY = 0x0,
    /// This message does not expect method return replies or error replies,
    /// even if it is of a type that can have a reply; the reply should be omitted.
    /// Note that `METHOD_CALL` is the only message type currently defined in
    /// this specification that can expect a reply, so the presence or absence
    /// of this flag in the other three message types that are currently documented
    /// is meaningless: replies to those message types should not be sent, whether
    /// this flag is present or not.
    NoReplyExpected = 0x1,
    /// The bus must not launch an owner for the destination name in response
    /// to this message.
    NoAutoStart = 0x2,
    /// This flag may be set on a method call message to inform the receiving
    /// side that the caller is prepared to wait for interactive authorization,
    /// which might take a considerable time to complete. For instance, if this
    /// flag is set, it would be appropriate to query the user for passwords or
    /// confirmation via Polkit or a similar framework.
    ///
    /// This flag is only useful when unprivileged code calls a more privileged
    /// method call, and an authorization framework is deployed that allows possibly
    /// interactive authorization. If no such framework is deployed it has no
    /// effect. This flag should not be set by default by client implementations.
    /// If it is set, the caller should also set a suitably long timeout on
    /// the method call to make sure the user interaction may complete.
    /// This flag is only valid for method call messages, and shall be
    /// ignored otherwise.
    ///
    /// Interaction that takes place as a part of the effect of the method being
    /// called is outside the scope of this flag, even if it could also be
    /// characterized as authentication or authorization. For instance, in a
    /// method call that directs a network management service to attempt to connect
    /// to a virtual private network, this flag should control how the network
    /// management service makes the decision
    /// "is this user allowed to change system network configuration?",
    /// but it should not affect how or whether the network management service
    /// interacts with the user to obtain the credentials that are required
    /// for access to the VPN.
    ///
    /// If a this flag is not set on a method call, and a service determines
    /// that the requested operation is not allowed without interactive authorization,
    /// but could be allowed after successful interactive authorization, it may
    /// return the `org.freedesktop.DBus.Error.InteractiveAuthorizationRequired` error.
    ///
    /// The absence of this flag does not guarantee that interactive authorization
    /// will not be applied, since existing services that pre-date this flag
    /// might already use interactive authorization. However, existing D-Bus APIs
    /// that will use interactive authorization should document that the call may
    /// take longer than usual, and new D-Bus APIs should avoid interactive authorization
    /// in the absence of this flag.
    AllowInteractiveAuthorization = 0x4,
};

/// The type of a D-Bus message.
pub const MessageType = enum(u8) {
    /// This is an invalid type.
    Invalid = 0,
    /// Method call. This message type may prompt a reply.
    MethodCall = 1,
    /// Method reply with returned data.
    MethodReturn = 2,
    /// Error reply. If the first argument exists and is a string, it is an error message.
    Error = 3,
    /// Signal emission.
    Signal = 4,
};

/// Errors that can occur when packing a D-Bus message header.
pub const MessageHeaderError = error{ArrayTooLarge};

/// Represents the header of a D-Bus message.
pub const MessageHeader = struct {
    /// Endianness flag; ASCII 'l' for little-endian or ASCII 'B' for big-endian.
    /// Both header and body are in this endianness.
    /// By default this library default to the native endian.
    endianess: Endian = .native,
    /// Message type. Unknown types must be ignored
    message_type: MessageType,
    /// Bitwise OR of flags. Unknown flags must be ignored.
    flags: u8,
    /// Major protocol version of the sending application. If the major protocol
    /// version of the receiving application does not match, the applications
    /// will not be able to communicate and the D-Bus connection must be
    /// disconnected. The major protocol version for this version of the
    /// specification is 1.
    proto_version: u8,

    /// Length in bytes of the message body, starting from the end of the header.
    /// The header ends after its alignment padding to an 8-boundary.
    body_length: u32,
    /// The serial of this message, used as a cookie by the sender to identify
    /// the reply corresponding to this request. This must not be zero.
    serial: u32,

    /// An array of zero or more header fields where the byte is the field code,
    /// and the variant is the field value. The message type determines which
    /// fields are required.
    header_fields: []const HeaderField,

    /// Packs the message header into its wire format.
    pub fn pack(this: @This(), allocator: Allocator) !ArrayList(u8) {
        const Byte = Value.Byte();
        const U32 = Value.Uint32();

        var buf: ArrayList(u8) = try .initCapacity(allocator, 256);
        var w: DBusWriter = .init(allocator, &buf, this.endianess);

        const order_char: u8 = switch (this.endianess) {
            .little => 'l',
            .big => 'B',
        };

        try Byte.new(order_char).ser(&w);

        try Byte.new(@intFromEnum(this.message_type)).ser(&w);
        try Byte.new(this.flags).ser(&w);
        try Byte.new(this.proto_version).ser(&w);

        try U32.new(this.body_length).ser(&w);
        try U32.new(this.serial).ser(&w);

        // 4) Array of header fields
        // Array length is u32 (4-aligned). Header is currently 12 bytes.
        // 12 % 4 == 0, so no padding needed for the length itself.
        const len_pos = buf.items.len;
        try buf.appendNTimes(allocator, 0, 4);

        const start_elems = buf.items.len;
        // Each element: 8-aligned struct:
        //   field[0]: BYTE code (1-aligned)
        //   field[1]: VARIANT (1-aligned) => write 'g' + payload
        for (this.header_fields) |hf| {
            try w.padTo(8);
            try Byte.new(@intFromEnum(hf.code)).ser(&w);
            try serHeaderFieldVariant(hf.value, &w);
        }

        // Patch array byte length
        const arr_bytes = buf.items.len - start_elems;
        if (arr_bytes > math.maxInt(u32)) return MessageHeaderError.ArrayTooLarge;
        w.writeU32At(len_pos, @intCast(arr_bytes));

        const header_length = buf.items.len;
        const padding_needed = (8 - (header_length % 8)) % 8;
        if (padding_needed > 0) {
            try buf.appendNTimes(allocator, 0, padding_needed);
        }

        // 5) Pad header to 8
        try w.padTo(8);

        return buf;
    }
};

header: MessageHeader,
body: []const u8,
allocator: Allocator = undefined,

/// Creates a new Message.
pub fn new(header: MessageHeader, body: []const u8) Message {
    return .{ .header = header, .body = body, .allocator = undefined };
}

/// Packs the message into its wire format.
pub fn pack(this: Message, allocator: Allocator) !ArrayList(u8) {
    // Ensure header has correct body_length
    var hdr = this.header;
    hdr.body_length = @intCast(this.body.len);

    var header_bytes = try hdr.pack(allocator);
    errdefer header_bytes.deinit(allocator);

    // The message is: header || body (body itself must already be validly marshalled)
    try header_bytes.appendSlice(allocator, this.body);
    return header_bytes;
}

/// Checks if the message is a signal with the given interface and member names.
pub fn isSignal(this: Message, interface: []const u8, member: []const u8) bool {
    if (this.header.message_type != .Signal) return false;
    var has_iface = false;
    var has_member = false;

    for (this.header.header_fields) |f| {
        switch (f.value) {
            .Interface => |s| if (mem.eql(u8, s, interface)) {
                has_iface = true;
            },
            .Member => |s| if (mem.eql(u8, s, member)) {
                has_member = true;
            },
            else => {},
        }
    }

    return has_iface and has_member;
}

/// Checks if the message is an Error.
pub fn isError(this: Message) bool {
    return this.header.message_type == .Error;
}

/// Returns the ErrorName if the message is an Error, otherwise null.
pub fn getErrorName(this: Message) ?[]const u8 {
    if (!this.isError()) return null;
    for (this.header.header_fields) |f| {
        if (f.code == .ErrorName) return f.value.ErrorName;
    }

    return null;
}

// Serializes a HeaderFieldValue as a D-Bus VARIANT.
fn serHeaderFieldVariant(hfv: HeaderFieldValue, w: *DBusWriter) !void {
    // We inline the variant emission: 'g' then aligned payload.
    switch (hfv) {
        .Path => |s| {
            // VARIANT signature = 's' (object path uses string encoding on the wire)
            try w.writeSignatureOf(Value.GPath); // signature 's'
            try w.padTo(dbusAlignOf(Value.GPath));
            try Value.ObjectPath().new(s).ser(w);
        },
        .Interface => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Member => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .ErrorName => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Destination => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Sender => |s| {
            try w.writeSignatureOf(Value.GStr);
            try w.padTo(dbusAlignOf(Value.GStr));
            try Value.String().new(s).ser(w);
        },
        .Signature => |sig| {
            try w.writeSignatureOf(Value.GSig); // inner type is 'g'
            try w.padTo(dbusAlignOf(Value.GSig)); // 1
            try Value.Signature().new(sig).ser(w);
        },
        .ReplySerial => |u| {
            try w.writeSignatureOf(u32);
            try w.padTo(dbusAlignOf(u32)); // 4
            try Value.Uint32().new(u).ser(w);
        },
        .UnixFds => |u| {
            try w.writeSignatureOf(u32);
            try w.padTo(dbusAlignOf(u32)); // 4
            try Value.Uint32().new(u).ser(w);
        },
    }
}
