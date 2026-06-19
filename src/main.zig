const std = @import("std");
const builtin = @import("builtin");

const dmtx = @cImport({
    @cInclude("dmtx.h");
});

const stbi = @cImport({
    @cInclude("stb_image.h");
});

// We write to stdout/stderr via libc's fwrite (raw bytes, no varargs)
// rather than std.io / std.Io, since Zig's standard I/O API has been in
// heavy flux across 0.13-0.16 (std.io was removed/replaced by std.Io in
// 0.16, with further changes expected pre-1.0). libc is already linked
// for libdmtx and stb_image, so fwrite is a stable choice that won't
// break on the next stdlib reshuffle. We format messages ourselves with
// std.fmt into a stack buffer rather than passing through C's variadic
// fprintf, since Zig's comptime format strings don't bridge to C varargs.
const c = @cImport({
    @cInclude("stdio.h");
});

// `stdout`/`stderr` are NOT simple constants on every platform/libc:
//   - glibc (most Linux): plain extern globals, non-optional - `c.stdout`
//     works directly.
//   - musl (e.g. -linux-musl targets): same globals, but translate-c
//     types them as *optional* pointers (`?*FILE`), so we must unwrap.
//   - Windows (MSVCRT): macros expanding to a runtime call,
//     __acrt_iob_func(1)/(2) - translate-c can't fold this to a comptime
//     constant ("comptime call of extern function").
//   - macOS (Darwin libc): macros expanding to the globals __stdoutp/
//     __stderrp, but translate-c turns the macro into an *inline function*
//     you must call: `c.stdout()`, not `c.stdout`.
// Route through small helpers, branching at comptime on target OS/ABI, so
// the same source builds correctly everywhere.
fn cStdout() *c.FILE {
    return switch (builtin.os.tag) {
        .windows => c.__acrt_iob_func(1),
        .macos => c.stdout(),
        else => if (builtin.abi == .musl) c.stdout.? else c.stdout,
    };
}

fn cStderr() *c.FILE {
    return switch (builtin.os.tag) {
        .windows => c.__acrt_iob_func(2),
        .macos => c.stderr(),
        else => if (builtin.abi == .musl) c.stderr.? else c.stderr,
    };
}

const ExitCode = enum(u8) {
    ok = 0,
    bad_args = 1,
    image_load_failed = 2,
    dmtx_image_create_failed = 3,
    dmtx_decode_create_failed = 4,
    no_region_found = 5,
    region_decode_failed = 6,
};

fn writeAllTo(stream: *c.FILE, bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = c.fwrite(bytes.ptr, 1, bytes.len, stream);
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    writeAllTo(cStderr(), msg);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const gpa = std.heap.page_allocator;

    var iter = std.process.Args.Iterator.initAllocator(init.args, gpa) catch {
        errPrint("failed to read command-line arguments\n", .{});
        return @intFromEnum(ExitCode.bad_args);
    };
    defer iter.deinit();

    _ = iter.next(); // skip argv[0]

    const path = iter.next() orelse {
        errPrint("usage: dmtx-cli <image-path>\n", .{});
        return @intFromEnum(ExitCode.bad_args);
    };

    // Null-terminated path for stb_image's C API.
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        errPrint("path too long\n", .{});
        return @intFromEnum(ExitCode.bad_args);
    };

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    // Force 3 channels (RGB) regardless of source format/channel count,
    // since that's what we feed to DmtxPack24bppRGB below.
    const pixels = stbi.stbi_load(path_z.ptr, &width, &height, &channels, 3);
    if (pixels == null) {
        const reason = stbi.stbi_failure_reason();
        if (reason != null) {
            errPrint("failed to load image '{s}': {s}\n", .{ path, std.mem.span(reason) });
        } else {
            errPrint("failed to load image '{s}': unknown error\n", .{path});
        }
        return @intFromEnum(ExitCode.image_load_failed);
    }
    defer stbi.stbi_image_free(pixels);

    const dmtx_img = dmtx.dmtxImageCreate(pixels, width, height, dmtx.DmtxPack24bppRGB);
    if (dmtx_img == null) {
        errPrint("dmtxImageCreate failed\n", .{});
        return @intFromEnum(ExitCode.dmtx_image_create_failed);
    }
    defer {
        var img_ptr = dmtx_img;
        _ = dmtx.dmtxImageDestroy(&img_ptr);
    }

    const dec = dmtx.dmtxDecodeCreate(dmtx_img, 1);
    if (dec == null) {
        errPrint("dmtxDecodeCreate failed\n", .{});
        return @intFromEnum(ExitCode.dmtx_decode_create_failed);
    }
    defer {
        var dec_ptr = dec;
        _ = dmtx.dmtxDecodeDestroy(&dec_ptr);
    }

    const region = dmtx.dmtxRegionFindNext(dec, null);
    if (region == null) {
        errPrint("no Data Matrix region found in '{s}'\n", .{path});
        return @intFromEnum(ExitCode.no_region_found);
    }
    defer {
        var region_ptr = region;
        _ = dmtx.dmtxRegionDestroy(&region_ptr);
    }

    const msg = dmtx.dmtxDecodeMatrixRegion(dec, region, dmtx.DmtxUndefined);
    if (msg == null) {
        errPrint("found a Data Matrix region but failed to decode it\n", .{});
        return @intFromEnum(ExitCode.region_decode_failed);
    }
    defer {
        var msg_ptr = msg;
        _ = dmtx.dmtxMessageDestroy(&msg_ptr);
    }

    const output_len: usize = @intCast(msg.*.outputIdx);
    const output_ptr: [*]const u8 = @ptrCast(msg.*.output);

    writeAllTo(cStdout(), output_ptr[0..output_len]);
    writeAllTo(cStdout(), "\n");

    return @intFromEnum(ExitCode.ok);
}
