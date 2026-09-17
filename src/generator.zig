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

const std = @import("std");
const mem = std.mem;
const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree into a writer.
pub fn generate(writer: anytype, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) !void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const plume = @import("plume");
        \\const Proxy = plume.Proxy;
        \\const GStr = plume.Value.GStr;
        \\const GPath = plume.Value.GPath;
        \\const GSig = plume.Value.GSig;
        \\const GUFd = plume.Value.GUFd;
        \\const GVariant = plume.Value.GVariant;
        \\
        \\
    );

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (mem.findScalarLast(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try writer.print(
            \\pub const {s}Proxy = struct {{
            \\    inner: Proxy,
            \\
            \\    pub fn init(conn: *plume.Connection
        , .{short_name});
        if (dest == null) try writer.writeAll(", dest: [:0]const u8");
        if (path == null) try writer.writeAll(", path: [:0]const u8");
        try writer.print(
            \\) {s}Proxy {{
            \\      return .{{ .inner = Proxy.init(conn
        , .{short_name});

        if (dest) |d| {
            try writer.print(", \"{s}\"", .{d});
        } else {
            try writer.writeAll(", dest");
        }

        if (path) |p| {
            try writer.print(", \"{s}\"", .{p});
        } else {
            try writer.writeAll(", path");
        }

        try writer.print(
            \\, "{s}") }};
            \\}}
            \\
            \\
        , .{iface.name});

        for (iface.methods) |method| {
            try writer.print("    pub fn {s}(self: {s}Proxy", .{ method.name, short_name });
            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (mem.eql(u8, arg.direction, "in")) {
                    try writer.writeAll(", ");
                    if (arg.name.len > 0) {
                        try writer.writeAll(arg.name);
                    } else {
                        try writer.print("arg{d}", .{in_idx});
                        in_idx += 1;
                    }
                    try writer.writeAll(": ");
                    try dbusTypeToZig(writer, arg.type, true);
                }
            }

            // Return type
            var out_sig: ?[]const u8 = null;
            for (method.args) |arg| {
                if (mem.eql(u8, arg.direction, "out")) {
                    out_sig = arg.type;
                    break;
                }
            }

            try writer.writeAll(") !");
            if (out_sig) |s| {
                try dbusTypeToZig(writer, s, false);
            } else {
                try writer.writeAll("void");
            }

            try writer.print(
                \\ {{
                \\        var res = try self.inner.call("{s}", .{{
            , .{method.name});

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (mem.eql(u8, arg.direction, "in")) {
                    if (!first) try writer.writeByte(',');
                    if (arg.name.len > 0) {
                        try writer.print(" {s}", .{arg.name});
                    } else {
                        try writer.print(" arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try writer.writeAll("});\n");

            try writer.writeAll("        defer res.deinit();\n");
            if (out_sig) |s| {
                try writer.writeAll("        return res.expectAlloc(");
                try dbusTypeToZig(writer, s, false);
                try writer.writeAll(");\n");
            }
            try writer.writeAll("    }\n\n");
        }

        for (iface.signals) |signal| {
            try writer.print(
                \\    pub fn connect{s}(
                \\        self: {s}Proxy,
                \\        ctx: anytype,
                \\        comptime callback: fn (@TypeOf(ctx), struct{{
            , .{ signal.name, short_name });
            var first = true;
            for (signal.args) |arg| {
                if (!first) try writer.writeByte(',');
                try writer.writeByte(' ');
                try dbusTypeToZig(writer, arg.type, false);
                first = false;
            }

            try writer.writeAll(
                \\}) void,
                \\  ) !void {
                \\      try self.inner.connectSignal(struct{
            );

            first = true;
            for (signal.args) |arg| {
                if (!first) try writer.writeByte(',');
                try writer.writeByte(' ');
                try dbusTypeToZig(writer, arg.type, false);
                first = false;
            }

            try writer.print(
                \\}}, "{s}", ctx, callback);
                \\  }}
                \\
            , .{signal.name});
        }

        try writer.writeAll("};\n\n");
    }
}

fn matchBasicType(sig: []const u8) ?[]const u8 {
    if (sig.len != 1) return null;
    return switch (sig[0]) {
        'y' => "u8",
        'b' => "bool",
        'n' => "i16",
        'q' => "u16",
        'i' => "i32",
        'u' => "u32",
        'x' => "i64",
        't' => "u64",
        'd' => "f64",
        's' => "GStr",
        'o' => "GPath",
        'g' => "GSig",
        'h' => "GUFd",
        'v' => "GVariant",
        else => null,
    };
}

fn nextSingleSig(sig: []const u8) ?[]const u8 {
    if (sig.len == 0) return null;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return sig[0..1],
        'a' => {
            const child = nextSingleSig(sig[1..]) orelse return null;
            return sig[0 .. 1 + child.len];
        },
        '(', '{' => {
            var depth: usize = 0;
            const open_char = sig[0];
            const close_char: u8 = if (open_char == '(') ')' else '}';
            for (sig, 0..) |c, idx| {
                if (c == open_char) depth += 1;
                if (c == close_char) {
                    depth -= 1;
                    if (depth == 0) {
                        return sig[0 .. idx + 1];
                    }
                }
            }
            return null;
        },
        else => return null,
    }
}

fn dbusTypeToZig(writer: anytype, sig: []const u8, is_param: bool) !void {
    if (matchBasicType(sig)) |basic| {
        return writer.writeAll(basic);
    }

    // Dictionaries: a{kv}
    if (sig.len >= 4 and mem.startsWith(u8, sig, "a{") and sig[sig.len - 1] == '}') {
        const key_char = sig[2];
        const val_sig = sig[3 .. sig.len - 1];
        if (key_char == 's' or key_char == 'o' or key_char == 'g') {
            try writer.writeAll("std.StringHashMap(");
        } else {
            try writer.print("std.AutoHashMap({s}, ", .{matchBasicType(sig[2..3]) orelse "u32"});
        }

        try dbusTypeToZig(writer, val_sig, false);
        return writer.writeByte(')');
    }

    // Arrays: a... (excluding dictionaries handled above)
    if (mem.startsWith(u8, sig, "a")) {
        const child_sig = sig[1..];
        try writer.writeAll("[]const ");
        return dbusTypeToZig(writer, child_sig, false);
    }

    // Structs / Tuples: (...)
    if (sig.len >= 2 and sig[0] == '(' and sig[sig.len - 1] == ')') {
        var inner = sig[1 .. sig.len - 1];
        try writer.writeAll("struct { ");
        var fst: bool = true;
        while (inner.len > 0) {
            if (!fst) try writer.writeAll(", ");
            const field_sig = nextSingleSig(inner) orelse break;
            try dbusTypeToZig(writer, field_sig, is_param);
            inner = inner[field_sig.len..];
            fst = false;
        }
        if (inner.len > 0) return error.InvalidType;
        try writer.writeAll(" }");
        return;
    }

    return error.InvalidType;
}
