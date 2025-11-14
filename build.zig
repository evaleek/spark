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
        "Disallow linking any system libraries",
    ) orelse false;

    const link_x11 = !no_link and b.option(
        bool,
        "x11",
        "Link the X11 system libraries (default for Linux/BSD targets)",
    ) orelse switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .illumos => true,
        else => false,
    };
    const link_x11_mode = b.option(
        LinkMode,
        "x11-link-mode",
        "Override default link mode for X11",
    ) orelse default_link_mode;

    const link_win32 = !no_link and b.option(
        bool,
        "win32",
        "Link the Win32 system libraries (default for Windows targets)",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => false,
    };
    const link_win32_mode = b.option(
        LinkMode,
        "win32-link-mode",
        "Override default link mode for Win32",
    ) orelse default_link_mode;

    const zon = @import("build.zig.zon");
    const zon_version: SemVer = try SemVer.parse(zon.version);
    const zon_name: [:0]const u8 = @tagName(zon.name);

    const options = b.addOptions();
    options.addOption([:0]const u8, "name", zon_name);
    options.addOption(SemVer, "version", zon_version);
    options.addOption(bool, "x11_linked", link_x11);
    options.addOption(bool, "win32_linked", link_win32);

    const mod = b.addModule(zon_name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addOptions("build_options", options);
    mod.addAnonymousImport("common", .{
        .root_source_file = b.path("src/common.zig"),
    });

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
}

const LinkMode = std.builtin.LinkMode;
const SemVer = std.SemanticVersion;
const log = std.log;
const std = @import("std");
