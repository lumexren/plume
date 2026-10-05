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

const InterfaceWrapper = @import("InterfaceWrapper.zig");
const DispatchResult = InterfaceWrapper.DispatchResult;
const Connection = @import("Connection.zig");
const Message = @import("Message.zig");
const MessageHeader = Message.MessageHeader;
const MessageHeaderField = MessageHeader.HeaderField;
const Decoder = @import("Decoder.zig");
const Encoder = @import("Encoder.zig");
const Value = @import("value/Value.zig");
const Wrappers = Value.Wrappers;
const GPath = Wrappers.GPath;
const GSig = Wrappers.GSig;
const GStr = Wrappers.GStr;
const GUFd = Wrappers.GUFd;
const GVariant = Wrappers.GVariant;

const std = @import("std");
const StringHashMap = std.StringHashMap;
const meta = std.meta;
const mem = std.mem;

fn isConnectionField(comptime FieldType: type, comptime FieldName: []const u8) bool {
    return FieldType == *Connection or mem.eql(u8, FieldName, "connection") or mem.eql(u8, FieldName, "conn");
}

pub fn getDispatchFn(comptime T: type) fn (*const InterfaceWrapper, *Connection, Message) anyerror!DispatchResult {
    return struct {
        fn dispatch(w: *const InterfaceWrapper, connection: *Connection, message: Message) anyerror!DispatchResult {
            const self_obj = @as(*T, @ptrCast(@alignCast(w.instance)));

            var member_name: ?[]const u8 = null;
            var iface_name: ?[]const u8 = null;
            for (message.header.header_fields) |f| {
                switch (f.value) {
                    .Member => |m| member_name = m,
                    .Interface => |i| iface_name = i,
                    else => {},
                }
            }
            const member = member_name orelse return .unhandled;

            // PropUnion Generation
            const PropUnion = blk: {
                comptime var union_fields_name: []const [:0]const u8 = &.{};
                comptime var union_fields_type: []const type = &.{};

                comptime var enum_fields_value: []const u16 = &.{};
                comptime var enum_fields_name: []const [:0]const u8 = &.{};
                comptime var count: usize = 0;

                const struct_info = @typeInfo(T).@"struct";
                inline for (struct_info.field_names, struct_info.field_types) |FieldName, FieldType| {
                    const type_info = @typeInfo(FieldType);
                    const DataType = if (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_property")) FieldType.DataType else FieldType;
                    const is_prop = if (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_property")) true else pblk: {
                        const is_signal = (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_signal"));
                        const is_conn = isConnectionField(FieldType, FieldName);
                        const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                        break :pblk !is_signal and !is_conn and !is_ptr;
                    };

                    if (is_prop) {
                        union_fields_name = union_fields_name ++ &[_][:0]const u8{FieldName};
                        union_fields_type = union_fields_type ++ &[_]type{DataType};
                        enum_fields_name = enum_fields_name ++ &[_][:0]const u8{FieldName};
                        enum_fields_value = enum_fields_value ++ &[_]u16{count};
                        count += 1;
                    }
                }

                if (count == 0) break :blk union { _dummy: void };

                const c = count;

                const TagType = @Enum(u16, .exhaustive, enum_fields_name[0..c], enum_fields_value[0..c]);

                break :blk @Union(.auto, TagType, union_fields_name[0..c], union_fields_type[0..c], &@splat(.{}));
            };

            if (iface_name != null and mem.eql(u8, iface_name.?, "org.freedesktop.DBus.Properties")) {
                if (mem.eql(u8, member, "GetAll")) {
                    var decoder: Decoder = .fromMessage(connection.allocator, message);
                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return .dispatched;
                    };

                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var dict: std.StringHashMap(VariantType) = .init(connection.allocator);
                        defer dict.deinit();

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_names, struct_info.field_types) |FieldName, FieldType| {
                            const type_info = @typeInfo(FieldType);
                            const is_wrapped = type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_property");
                            const is_prop = is_wrapped or blk: {
                                const is_signal = (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_signal"));
                                const is_conn = isConnectionField(FieldType, FieldName);
                                const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                break :blk !is_signal and !is_conn and !is_ptr;
                            };
                            const readable = if (is_wrapped) FieldType.AccessMode != .Write else true;

                            if (is_prop and readable) {
                                const val_field = @field(self_obj, FieldName);
                                const val = if (is_wrapped) val_field.value else val_field;
                                try dict.put(FieldName, VariantType.new(@unionInit(PropUnion, FieldName, val)));
                            }
                        }

                        var encoder: Encoder = try .encode(connection.allocator, dict);
                        defer encoder.deinit();
                        try connection.sendReply(message, encoder);

                        return .dispatched; // to this interface
                    } else {
                        return .unhandled; // not this interface
                    }
                } else if (mem.eql(u8, member, "Get")) {
                    var decoder: Decoder = .fromMessage(connection.allocator, message);
                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return .dispatched;
                    };
                    const prop_name = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return .dispatched;
                    };

                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        const VariantType = Value.Variant(PropUnion);
                        var found = false;
                        var val_variant: VariantType = undefined;

                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_names, struct_info.field_types) |FieldName, FieldType| {
                            if (!found and mem.eql(u8, FieldName, prop_name.s)) {
                                const type_info = @typeInfo(FieldType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_signal"));
                                    const is_conn = isConnectionField(FieldType, FieldName);
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };

                                const readable = if (is_wrapped) FieldType.AccessMode != .Write else true;

                                if (is_prop) {
                                    if (readable) {
                                        const val_field = @field(self_obj, FieldName);
                                        const val = if (is_wrapped) val_field.value else val_field;
                                        val_variant = VariantType.new(@unionInit(PropUnion, FieldName, val));
                                        found = true;
                                    }
                                }
                            }
                        }

                        if (found) {
                            var encoder: Encoder = try .encode(connection.allocator, val_variant);
                            defer encoder.deinit();
                            try connection.sendReply(message, encoder);
                        } else {
                            try connection.sendError(message, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown or unreadable property");
                        }

                        return .dispatched; // to this interface
                    }

                    return .unhandled; // not this interface
                } else if (mem.eql(u8, member, "Set")) {
                    var decoder: Decoder = .fromMessage(connection.allocator, message);
                    const requested_iface = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid interface argument");
                        return .dispatched;
                    };
                    const prop_name = decoder.decode(GStr) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid property name argument");
                        return .dispatched;
                    };
                    const val_union = decoder.decode(PropUnion) catch {
                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidSignature", "Property value signature mismatch");
                        return .dispatched;
                    };

                    if (mem.eql(u8, requested_iface.s, w.interface_name)) {
                        var found = false;
                        const struct_info = @typeInfo(T).@"struct";
                        inline for (struct_info.field_names, struct_info.field_types) |FieldName, FieldType| {
                            if (!found and mem.eql(u8, FieldName, prop_name.s)) {
                                const type_info = @typeInfo(FieldType);
                                const is_wrapped = type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_property");
                                const is_prop = is_wrapped or blk: {
                                    const is_signal = (type_info == .@"struct" and @hasDecl(FieldType, "__is_plume_signal"));
                                    const is_conn = isConnectionField(FieldType, FieldName);
                                    const is_ptr = (type_info == .pointer and type_info.pointer.size != .slice);
                                    break :blk !is_signal and !is_conn and !is_ptr;
                                };

                                const writable = if (is_wrapped) FieldType.AccessMode != .Read else false;

                                if (is_prop) {
                                    if (writable) {
                                        if (meta.activeTag(val_union) == meta.stringToEnum(meta.Tag(PropUnion), FieldName)) {
                                            const new_val = @field(val_union, FieldName);

                                            if (is_wrapped) {
                                                @field(self_obj, FieldName).value = new_val;
                                            } else {
                                                @field(self_obj, FieldName) = new_val;
                                            }

                                            found = true;

                                            // Emit PropertiesChanged signal
                                            {
                                                const VariantType = Value.Variant(PropUnion);
                                                var dict: StringHashMap(VariantType) = .init(connection.allocator);
                                                defer dict.deinit();

                                                try dict.put(FieldName, VariantType.new(@unionInit(PropUnion, FieldName, new_val)));

                                                const empty_strs = [_]GStr{};
                                                const args = .{ GStr.new(w.interface_name), dict, Value.Array(GStr).new(&empty_strs) };

                                                var sig_encoder: Encoder = try .encode(connection.allocator, args);
                                                defer sig_encoder.deinit();
                                                const serial = connection.nextSerial();

                                                const sig_header: MessageHeader = .{
                                                    .message_type = .Signal,
                                                    .flags = 0,
                                                    .proto_version = 1,
                                                    .body_length = @intCast(sig_encoder.body().len),
                                                    .serial = serial,
                                                    .header_fields = @constCast(&[_]MessageHeaderField{
                                                        .{ .code = .Path, .value = .{ .Path = w.path } },
                                                        .{ .code = .Interface, .value = .{ .Interface = "org.freedesktop.DBus.Properties" } },
                                                        .{ .code = .Member, .value = .{ .Member = "PropertiesChanged" } },
                                                        .{ .code = .Signature, .value = .{ .Signature = sig_encoder.signature() } },
                                                    }),
                                                };

                                                const sig_message: Message = .new(sig_header, sig_encoder.body());
                                                try connection.sendMessage(sig_message);
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if (found) {
                            var encoder: Encoder = try .encode(connection.allocator, .{}); // Void return;
                            defer encoder.deinit();
                            try connection.sendReply(message, encoder);
                        } else {
                            try connection.sendError(message, "org.freedesktop.DBus.Error.UnknownProperty", "Property does not exist or is not writable");
                        }

                        return .dispatched; // to this interface
                    }

                    return .unhandled; // not this interface
                }
            }

            // Dispatch to method
            inline for (@typeInfo(T).@"struct".decl_names) |decl_name| {
                const field_val = @field(T, decl_name);
                const field_type = @TypeOf(field_val);

                if (@typeInfo(field_type) == .@"fn") {
                    if (!mem.eql(u8, decl_name, "init")) {
                        const fn_info = @typeInfo(field_type).@"fn";
                        if (fn_info.param_types.len > 0 and fn_info.param_types[0] == *T) {
                            if (mem.eql(u8, member, decl_name)) {
                                var decoder: Decoder = .fromMessage(connection.allocator, message);
                                const ArgsType = meta.ArgsTuple(field_type);
                                var args: ArgsType = undefined;
                                args[0] = self_obj;

                                inline for (fn_info.param_types[1..], 1..) |param_type, i| {
                                    args[i] = decoder.decode(param_type.?) catch {
                                        try connection.sendError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid method arguments");
                                        return .dispatched;
                                    };
                                }

                                const CallRetT = fn_info.return_type.?;
                                const result = if (@typeInfo(CallRetT) == .error_union)
                                    @call(.auto, field_val, args) catch |err| {
                                        try connection.sendError(message, "org.freedesktop.DBus.Error.Failed", @errorName(err));
                                        return .dispatched;
                                    }
                                else
                                    @call(.auto, field_val, args);

                                var encoder: Encoder = try .encode(connection.allocator, result);
                                defer encoder.deinit();
                                try connection.sendReply(message, encoder);
                                return .dispatched;
                            }
                        }
                    }
                }
            }

            return .unhandled;
        }
    }.dispatch;
}
