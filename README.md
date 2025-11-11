# xwin

__xwin__ is a Zig windowing abstraction layer
focused on providing a flexible, close-to-native-API interface
while still hiding the boilerplate.

The library is still in early development.

## Planned features

On platforms where it is supported (X11, Win32, potentially Wayland with an extension)
xwin exposes/will expose the window event queue for direct polling.
On all platforms, an emulated event queue will be provided
for a unified cross-platform interface.

Partial implementation:

- X11 (Linux/BSD)

Planned implementation:

- Win32 (Windows)
- Wayland (Linux/BSD)
- Cocoa (MacOS)
- Consoles
