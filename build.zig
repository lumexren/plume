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
const Build = std.Build;
const LtoMode = std.zig.LtoMode;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lto: LtoMode = switch (optimize) {
        .debug, .safe => .none,
        .small => .thin,
        .fast => .full,
    };

    const mod = b.addModule("plume", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "plume-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    exe.lto = lto;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("test-app", "Run the test app");
    run_step.dependOn(&run_cmd.step);

    const server_exe = b.addExecutable(.{
        .name = "plume-server-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/server_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    server_exe.lto = lto;

    const run_server = b.addRunArtifact(server_exe);
    const server_step = b.step("test-server", "Run the server test app");
    server_step.dependOn(&run_server.step);

    const client_exe = b.addExecutable(.{
        .name = "plume-client-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/client_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    client_exe.lto = lto;

    const run_client = b.addRunArtifact(client_exe);
    const client_step = b.step("test-client", "Run the client test app");
    client_step.dependOn(&run_client.step);

    const intro_exe = b.addExecutable(.{
        .name = "plume-introspection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/introspector.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    intro_exe.lto = lto;

    b.installArtifact(intro_exe);

    const run_intro = b.addRunArtifact(intro_exe);
    const intro_step = b.step("introspection", "Run the introspection demo");
    intro_step.dependOn(&run_intro.step);

    const gen_exe = b.addExecutable(.{
        .name = "plume-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/generate_proxy.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    gen_exe.lto = lto;

    b.installArtifact(gen_exe);

    const run_gen = b.addRunArtifact(gen_exe);
    const gen_step = b.step("generate", "Generate Zig proxy from D-Bus introspection");
    gen_step.dependOn(&run_gen.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
