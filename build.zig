const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dmtx-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // NOTE (Zig 0.16): addCSourceFiles/addCSourceFile/addIncludePath/linkLibC
    // are methods on *Module now, not on *Compile. Call them via
    // exe.root_module rather than exe directly.
    const mod = exe.root_module;

    // --- libdmtx (vendored C source) ---
    // IMPORTANT: libdmtx's dmtx.c #includes every other .c file directly
    // (a deliberate unity build - see the comment at dmtx.c:56). Compiling
    // the other .c files as separate translation units, as well as
    // dmtx.c, causes duplicate-symbol errors. Only dmtx.c should be passed
    // to the compiler.
    // VERSION is normally supplied by an autotools-generated config.h;
    // we just define it directly instead of vendoring that generated file.
    mod.addCSourceFile(.{
        .file = b.path("vendor/libdmtx/dmtx.c"),
        .flags = &.{
            "-std=c99",
            "-DVERSION=\"0.7.9\"",
        },
    });
    mod.addIncludePath(b.path("vendor/libdmtx"));

    // --- stb_image (vendored single-header C library) ---
    // We compile a tiny shim .c that defines STB_IMAGE_IMPLEMENTATION once
    // and includes stb_image.h, giving us a normal translation unit.
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addIncludePath(b.path("vendor/stb"));

    mod.link_libc = true;

    b.installArtifact(exe);

    // `zig build run -- <path>` convenience step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run dmtx-cli");
    run_step.dependOn(&run_cmd.step);
}
