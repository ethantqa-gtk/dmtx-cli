# dmtx-cli

A single statically-linked CLI that reads an image file and prints the
decoded Data Matrix barcode contents. Built with Zig, vendoring:

- **libdmtx** (BSD-2-Clause) — Data Matrix detection/decoding, real source
  pulled from https://github.com/dmtx/libdmtx
- **stb_image.h** (public domain) — PNG/JPEG/BMP/etc. image loading, from
  https://github.com/nothings/stb

No system install of either library is required — both are vendored as
source under `vendor/` and compiled directly into the executable by
`build.zig`.

## Prerequisites

Tested and verified working against **Zig 0.16.0** specifically (the
build-system API moved several methods from `*Compile` to `*Module`
between 0.13 and 0.16 — see "Zig API drift" below if you're on a
different version). Install from https://ziglang.org/download/ or, if
that's blocked on your network, via PyPI: `pip install ziglang` then run
it as `python3 -m ziglang build ...` instead of `zig build ...`.

Verify with:
```
zig version
```

## Build (native, current OS)

```
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/dmtx-cli` (or `dmtx-cli.exe` on
Windows).

## Run

```
zig build run -- path/to/image.png
```

or directly:

```
./zig-out/bin/dmtx-cli path/to/image.png
```

On success it prints the decoded Data Matrix text to stdout and exits 0.
On failure it prints a diagnostic to stderr and exits non-zero (see exit
codes in `src/main.zig`'s `ExitCode` enum).

## Cross-compiling

This is the main point of using Zig here — you can produce binaries for
all three target OSes from a single machine, with no platform-specific
toolchain installs:

```
# Linux x86_64 (musl = fully static, no glibc dependency)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe

# macOS Intel
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe

# Windows x86_64
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

Each invocation writes its output to `zig-out/bin/` — re-run `zig build`
for a different target and it'll overwrite the previous output, so copy
binaries elsewhere between runs if you want to keep more than one target's
build around, or pass distinct `--prefix` paths.

## Notes / things worth checking before relying on this

- **Image loading**: `stb_image` is forced to load images as 3-channel
  RGB (`stbi_load(..., 3)`), which matches `DmtxPack24bppRGB`. This covers
  PNG, JPEG, BMP, GIF (first frame), TGA, and a few others — see
  `vendor/stb/stb_image.h`'s header comment for the full format list.
  PDFs are NOT supported directly; if your input is a PDF, render the
  page to PNG/JPEG first (e.g. with a PDF rendering tool) before passing
  it to this CLI.
- **Multiple regions**: this only decodes the *first* Data Matrix region
  found in the image (`dmtxRegionFindNext` called once). If a page can
  have more than one code, the loop would need to call
  `dmtxRegionFindNext` repeatedly until it returns null.
- **Decode tuning**: libdmtx has many tunable properties (timeout,
  scan gap, edge thresholds, etc.) via `dmtxDecodeSetProp` /
  `dmtxImageSetProp` that aren't exposed here. If decoding struggles on
  a specific image, that's the first place to add options — start by
  checking `vendor/libdmtx/dmtx.h`'s `DmtxProperty` enum.
- **Zig API drift**: Zig is pre-1.0 and its build-system/stdlib APIs have
  changed significantly between versions. This code targets **Zig
  0.16.0** specifically. Notable things that changed and are handled
  here: `addCSourceFile(s)`/`addIncludePath` moved from `*Compile` to
  `*Module`; `std.process.args()` was replaced by a `main(init:
  std.process.Init.Minimal)` signature; `std.io` was removed in favor of
  a new `std.Io` interface (this code sidesteps that entirely by calling
  libc's `fwrite` directly, which is more version-stable). If you're on
  an older or newer Zig and `zig build` fails, the error will usually
  point at one of these.
- **libdmtx is a unity build**: `vendor/libdmtx/dmtx.c` `#include`s every
  other `.c` file in the directory itself (see the comment around line
  56 of that file). `build.zig` only compiles `dmtx.c` for this reason —
  compiling the others as separate translation units as well causes
  duplicate-symbol errors. `VERSION` is defined via a `-D` compiler flag
  instead of vendoring the autotools-generated `config.h` that would
  normally supply it.
- **`stdout`/`stderr` are not portable C constants**: this tripped up
  cross-compilation specifically. glibc exposes them as plain pointers,
  musl as *optional* pointers, Darwin (macOS) as inline functions you
  must call (`c.stdout()`), and Windows/MSVCRT as a runtime function call
  (`__acrt_iob_func(1)`) that Zig's translate-c can't fold into a
  compile-time constant. `src/main.zig` has small `cStdout()`/`cStderr()`
  helpers that branch on `builtin.os.tag`/`builtin.abi` to handle all
  four correctly from one source file.

## What was actually verified (and how)

Unlike the first pass at this file, every claim below was checked
against a real Zig 0.16.0 compiler (installed via `pip install ziglang`)
in a sandboxed environment, not just reasoned about:

- ✅ **Native Linux (glibc) build**: compiles clean, binary runs.
- ✅ **End-to-end decode test**: generated a real Data Matrix PNG encoding
  the string `"HELLO123"` using libdmtx's own encoder (a separate throwaway
  test program, not part of this repo), then ran it through the compiled
  `dmtx-cli` and got `HELLO123` back, exit code 0.
- ✅ **JPEG input**: same test image re-saved as `.jpg` — decoded correctly.
- ✅ **Rotated input**: same test image rotated 15° — decoded correctly
  (libdmtx's rotation tolerance worked as expected).
- ✅ **Error paths**: no-args and nonexistent-file cases print the right
  message to stderr and return the right exit code.
- ✅ **Cross-compile to `x86_64-linux-musl`**: compiles clean, binary
  confirmed statically linked via `ldd` ("not a dynamic executable"),
  and re-ran the full PNG/JPEG/rotated decode test suite against it
  successfully.
- ✅ **Cross-compile to `x86_64-windows-gnu`**: compiles clean, produces a
  real `PE32+ executable (console) x86-64, for MS Windows` per `file`.
  **Not actually executed** (no Wine available in the sandbox), so the
  Windows-specific `cStdout()`/`cStderr()` branch is confirmed to *compile*
  correctly but not confirmed to *run* correctly — please treat your
  first real run on Windows as the actual test of that path.
- ✅ **Cross-compile to `aarch64-macos`**: compiles clean, produces a real
  `Mach-O 64-bit arm64 executable` per `file`. Same caveat as Windows —
  not actually executed, since this sandbox has no macOS runtime.
- ✅ **Cross-compile to `x86_64-macos`**: compiles clean, produces a real
  `Mach-O 64-bit x86_64 executable` per `file`. Same caveat as above.

## License

- `vendor/libdmtx/`: BSD-2-Clause — see `vendor/libdmtx/LICENSE`.
- `vendor/stb/stb_image.h`: public domain / MIT (dual-licensed, see the
  header comment at the top of the file).
- Everything else in this repo (`build.zig`, `src/main.zig`): do
  whatever you want with it.
