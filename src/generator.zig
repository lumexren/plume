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
const ArrayList = std.ArrayList;
const mem = std.mem;
const Allocator = mem.Allocator;

const introspection = @import("introspection.zig");

/// Generates Zig Proxy source code from a D-Bus Node tree.
pub fn generate(allocator: Allocator, node: introspection.Node, dest: ?[]const u8, path: ?[]const u8) ![]const u8 {
    var out: ArrayList(u8) = try .initCapacity(allocator, 2048);
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "const plume = @import(\"plume\");\n");
    try out.appendSlice(allocator, "const Proxy = plume.Proxy;\n");
    try out.appendSlice(allocator, "const MethodResult = plume.MethodResult;\n");
    try out.appendSlice(allocator, "const GStr = plume.Value.GStr;\n\n");

    for (node.interfaces) |iface| {
        // Simple name cleaning (e.g. org.freedesktop.DBus -> DBus)
        var short_name = iface.name;
        if (mem.lastIndexOfScalar(u8, iface.name, '.')) |pos| {
            short_name = iface.name[pos + 1 ..];
        }

        try out.appendSlice(allocator, "pub const ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy = struct {\n");
        try out.appendSlice(allocator, "    inner: Proxy,\n\n");

        try out.appendSlice(allocator, "    pub fn init(conn: *plume.Connection");
        if (dest == null) try out.appendSlice(allocator, ", dest: [:0]const u8");
        if (path == null) try out.appendSlice(allocator, ", path: [:0]const u8");
        try out.appendSlice(allocator, ") ");
        try out.appendSlice(allocator, short_name);
        try out.appendSlice(allocator, "Proxy {\n");
        try out.appendSlice(allocator, "        return .{ .inner = Proxy.init(conn, ");
        if (dest) |d| {
            try out.print(allocator, "\"{s}\"", .{d});
        } else {
            try out.appendSlice(allocator, "dest");
        }
        try out.appendSlice(allocator, ", ");
        if (path) |p| {
            try out.print(allocator, "\"{s}\"", .{p});
        } else {
            try out.appendSlice(allocator, "path");
        }
        try out.appendSlice(allocator, ", \"");
        try out.appendSlice(allocator, iface.name);
        try out.appendSlice(allocator, "\") };\n");
        try out.appendSlice(allocator, "    }\n\n");

        for (iface.methods) |method| {
            try out.appendSlice(allocator, "    pub fn ");
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "(self: ");
            try out.appendSlice(allocator, short_name);
            try out.appendSlice(allocator, "Proxy");

            // Generate In args
            var in_idx: usize = 0;
            for (method.args) |arg| {
                if (mem.eql(u8, arg.direction, "in")) {
                    try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{in_idx});
                    }
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, try dbusTypeToZig(arg.type, true));
                    in_idx += 1;
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

            const out_type = if (out_sig) |s| try dbusTypeToZig(s, false) else "void";
            const is_method_result = mem.eql(u8, out_type, "MethodResult");

            try out.appendSlice(allocator, ") !");
            try out.appendSlice(allocator, out_type);
            try out.appendSlice(allocator, " {\n");

            if (is_method_result) {
                try out.appendSlice(allocator, "        const res = try self.inner.call(\"");
            } else {
                try out.appendSlice(allocator, "        var res = try self.inner.call(\"");
            }
            try out.appendSlice(allocator, method.name);
            try out.appendSlice(allocator, "\", .{");

            var call_idx: usize = 0;
            var first = true;
            for (method.args) |arg| {
                if (mem.eql(u8, arg.direction, "in")) {
                    if (!first) try out.appendSlice(allocator, ", ");
                    if (arg.name.len > 0) {
                        try out.appendSlice(allocator, arg.name);
                    } else {
                        try out.print(allocator, "arg{d}", .{call_idx});
                    }
                    first = false;
                    call_idx += 1;
                }
            }
            try out.appendSlice(allocator, "});\n");

            if (mem.eql(u8, out_type, "void")) {
                try out.appendSlice(allocator, "        res.deinit();\n");
            } else if (is_method_result) {
                try out.appendSlice(allocator, "        return res;\n");
            } else {
                try out.appendSlice(allocator, "        return res.expect(");
                try out.appendSlice(allocator, out_type);
                try out.appendSlice(allocator, ");\n");
            }
            try out.appendSlice(allocator, "    }\n");
        }

        try out.appendSlice(allocator, "};\n\n");
    }

    return out.toOwnedSlice(allocator);
}

/// Maps a D-Bus type signature character to its corresponding Zig type (internal helper).
fn dbusTypeToZig(sig: []const u8, is_param: bool) ![]const u8 {
    if (mem.eql(u8, sig, "s")) return "GStr";
    if (mem.eql(u8, sig, "u")) return "u32";
    if (mem.eql(u8, sig, "b")) return "bool";
    if (mem.eql(u8, sig, "as")) return "[]const GStr";
    if (mem.eql(u8, sig, "i")) return "i32";
    if (mem.eql(u8, sig, "x")) return "i64";
    if (mem.eql(u8, sig, "t")) return "u64";
    if (mem.eql(u8, sig, "d")) return "f64";

    if (is_param) return "anytype";
    return "MethodResult";
}
