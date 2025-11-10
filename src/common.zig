pub const ConnectionError = error{
    OutOfMemory,
    HostDown,
    ConnectionFailed,
};

pub const WindowCreationOptions = struct {
    name: [:0]const u8,
    width: u16,
    height: u16,
};

pub const WindowCreationError = error{
    OutOfMemory,
};
