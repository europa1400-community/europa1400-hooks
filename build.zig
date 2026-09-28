const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const cflags = &[_][]const u8{ "-Wall", "-fno-stack-protector" };

    // ---- Build MinHook static library ----
    const minhook = b.addStaticLibrary(.{
        .name = "minhook",
        .target = target,
        .optimize = optimize,
    });

    minhook.addIncludePath(b.path("vendor/minhook/include"));
    minhook.addCSourceFiles(.{
        .files = &.{
            "vendor/minhook/src/buffer.c",
            "vendor/minhook/src/hde/hde32.c",
            "vendor/minhook/src/hde/hde64.c",
            "vendor/minhook/src/hook.c",
            "vendor/minhook/src/trampoline.c",
        },
        .flags = cflags,
    });

    minhook.linkLibC();
    minhook.installHeader(b.path("vendor/minhook/include/MinHook.h"), "MinHook.h");

    // ---- Build injector executable ----
    const injector = b.addExecutable(.{
        .name = "injector",
        .target = target,
        .optimize = optimize,
    });

    injector.addCSourceFile(.{
        .file = b.path("src/injector.c"),
        .flags = cflags,
    });
    injector.linkLibC();
    b.installArtifact(injector);

    const allocator = b.allocator;

    // ---- Build proxy DLLs ----
    const dll_names = &[_][]const u8{ "kernel32", "server", "ws2_32" };
    for (dll_names) |name| {
        const dll = b.addSharedLibrary(.{
            .name = b.fmt("hook_{s}", .{name}),
            .target = target,
            .optimize = optimize,
        });

        const proxy_path = try std.fmt.allocPrint(allocator, "src/{s}_proxy.c", .{name});
        dll.addCSourceFile(.{
            .file = b.path(proxy_path),
            .flags = cflags,
        });

        dll.linkLibrary(minhook);
        dll.linkSystemLibrary("shlwapi");
        dll.linkSystemLibrary("ws2_32");
        b.installArtifact(dll);
    }

    // ---- Clean step ----
    const clean_step = b.step("clean", "Remove zig-out and zig-cache directories");
    clean_step.makeFn = cleanAll;
}

fn cleanAll(_: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
    const cwd = std.fs.cwd();
    try deleteIfExists(cwd, "zig-out");
    try deleteIfExists(cwd, "zig-cache");
}

fn deleteIfExists(cwd: std.fs.Dir, path: []const u8) !void {
    if (cwd.access(path, .{})) |_| {
        std.log.info("Deleting {s}", .{path});
        try cwd.deleteTree(path);
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
}
