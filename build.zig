// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 lumexren
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

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "plume",
        .root_module = mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "plume-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main.zig"),
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
    run_cmd.addPassthruArgs();

    const run_step = b.step("test-app", "Run the test app");
    run_step.dependOn(&run_cmd.step);

    const playground_exe = b.addExecutable(.{
        .name = "plume-playground",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/playground.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    playground_exe.lto = lto;

    const run_plgd_cmd = b.addRunArtifact(playground_exe);
    run_plgd_cmd.step.dependOn(b.getInstallStep());
    run_plgd_cmd.addPassthruArgs();

    const run_plgd_step = b.step("playground", "Run the playground test file");
    run_plgd_step.dependOn(&run_plgd_cmd.step);

    const server_exe = b.addExecutable(.{
        .name = "plume-server-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/server_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    server_exe.lto = lto;

    const run_server = b.addRunArtifact(server_exe);
    run_server.addPassthruArgs();
    const server_step = b.step("test-server", "Run the server test app");
    server_step.dependOn(&run_server.step);

    const client_exe = b.addExecutable(.{
        .name = "plume-client-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/client_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    client_exe.lto = lto;

    const run_client = b.addRunArtifact(client_exe);
    run_client.addPassthruArgs();
    const client_step = b.step("test-client", "Run the client test app");
    client_step.dependOn(&run_client.step);

    const concurrency_exe = b.addExecutable(.{
        .name = "plume-concurrency-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/concurrency_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    concurrency_exe.lto = lto;

    const run_concurrency = b.addRunArtifact(concurrency_exe);
    run_concurrency.addPassthruArgs();
    const concurrency_step = b.step("test-concurrency", "Run concurrency and lifecycle tests");
    concurrency_step.dependOn(&run_concurrency.step);

    const fd_exe = b.addExecutable(.{
        .name = "plume-unix-fd-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unix_fd_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "plume", .module = mod },
            },
        }),
    });

    fd_exe.lto = lto;

    const run_fd = b.addRunArtifact(fd_exe);
    run_fd.addPassthruArgs();
    const fd_step = b.step("test-fd", "Run UNIX file descriptor passing tests");
    fd_step.dependOn(&run_fd.step);

    const intro_exe = b.addExecutable(.{
        .name = "plume-introspection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/introspector.zig"),
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
    run_intro.addPassthruArgs();
    const intro_step = b.step("introspection", "Run the introspection demo");
    intro_step.dependOn(&run_intro.step);

    const gen_exe = b.addExecutable(.{
        .name = "plume-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/generate_proxy.zig"),
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
    run_gen.addPassthruArgs();
    const gen_step = b.step("generate", "Generate Zig proxy from D-Bus introspection");
    gen_step.dependOn(&run_gen.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .name = "plume",
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    const check_step = b.step("check", "Check compilation of all artifacts");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&playground_exe.step);
    check_step.dependOn(&server_exe.step);
    check_step.dependOn(&client_exe.step);
    check_step.dependOn(&concurrency_exe.step);
    check_step.dependOn(&fd_exe.step);
    check_step.dependOn(&intro_exe.step);
    check_step.dependOn(&gen_exe.step);
    check_step.dependOn(&lib.step);

    const docs_step = b.step("docs", "Generate HTML documentation");
    const docs_install = b.addInstallDirectory(.{
        .source_dir = mod_tests.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs_install.step);
}
