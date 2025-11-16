pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const default_link_mode = b.option(
        LinkMode,
        "link-mode",
        "Global backend library link mode (default: static)",
    ) orelse LinkMode.static;
    const no_link = b.option(
        bool,
        "no-link",
        "Disallow linking any system libraries (default: false)",
    ) orelse false;

    const link_x11 = ( b.option(
        bool,
        "x11",
        "Link the X11 system libraries (default for Linux/BSD targets)",
    ) orelse switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .illumos => true,
        else => false,
    }) and !no_link;
    const link_x11_mode = b.option(
        LinkMode,
        "x11-link-mode",
        "Override default link mode for X11",
    ) orelse default_link_mode;
    // All buildable backends will by default skip unit tests
    // when the host daemon or system libraries are missing.
    const x11_force_test_host = b.option(
        bool,
        "x11-test-host",
        "Disallow X11 unit test skips when system is missing X (default: false)",
    ) orelse false;

    const link_win32 = ( b.option(
        bool,
        "win32",
        "Link the Win32 system libraries (default for Windows targets)",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => false,
    }) and !no_link;
    const link_win32_mode = b.option(
        LinkMode,
        "win32-link-mode",
        "Override default link mode for Win32",
    ) orelse default_link_mode;
    // All buildable backends will by default skip unit tests
    // when the host daemon or system libraries are missing.
    const win32_force_test_host = b.option(
        bool,
        "win32-test-host",
        "Disallow Win32 unit test skips when system is missing win32 (default: false)",
    ) orelse false;

    const zon = @import("build.zig.zon");
    const zon_version: SemVer = try SemVer.parse(zon.version);
    const zon_name: [:0]const u8 = @tagName(zon.name);

    const options = b.addOptions();
    options.addOption([:0]const u8, "name", zon_name);
    options.addOption(SemVer, "version", zon_version);
    options.addOption(bool, "x11_linked", link_x11);
    options.addOption(bool, "x11_force_test_host", x11_force_test_host);
    options.addOption(bool, "win32_linked", link_win32);
    options.addOption(bool, "win32_force_test_host", win32_force_test_host);

    const mod = b.addModule(zon_name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addOptions("build_options", options);

    if (link_x11) {
        mod.linkSystemLibrary("X11", .{
            .needed = false,
            .preferred_link_mode = link_x11_mode,
        });
        mod.linkSystemLibrary("Xrandr", .{
            .needed = false,
            .preferred_link_mode = link_x11_mode,
        });
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("src/X11/x11.h"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("x11", translate.createModule());
    }

    if (link_win32) {
        mod.linkSystemLibrary("user32", .{
            .needed = false,
            .preferred_link_mode = link_win32_mode,
        });
        const translate = b.addTranslateC(.{
            .root_source_file = b.path("src/Win32/win32.h"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("win32", translate.createModule());
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const window_test_exe = b.addExecutable(.{
        .name = b.fmt("{s}-test-{s}", .{
            zon_name,
            @tagName(target.result.os.tag),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_window.zig"),
            .imports = &.{ .{ .name = zon_name, .module = mod } },
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_window_test = b.addRunArtifact(window_test_exe);
    const window_test_step = b.step("test-window", "Launch a test window");
    window_test_step.dependOn(&run_mod_tests.step);
    window_test_step.dependOn(&run_window_test.step);
}

const LinkMode = std.builtin.LinkMode;
const SemVer = std.SemanticVersion;
const log = std.log;
const std = @import("std");
