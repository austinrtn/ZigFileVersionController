pub const JsonEntry = struct {
    dir: []const u8,
    file: []const u8,
    full_path: []const u8,

    hash: []const u8,
    version: usize = 0,
};

