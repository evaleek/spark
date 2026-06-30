# Spark

__Spark__ is a Zig windowing abstraction layer
focused on providing a flexible, close-to-native-API interface
while still managing the boilerplate.

The library is still in early development.

Current progress:

- Most Win32 function/type wrappers
- Unix stream socket connection and POD marshaling
- XML parsing implemented with finite-state machine,
  translating Wayland protocol XML into Zig `comptime` data

Planned implementation:

- Wayland (Linux/BSD)
- Win32 (Windows)
- Consoles
- Cocoa (MacOS)
- X11 (Linux/BSD)
