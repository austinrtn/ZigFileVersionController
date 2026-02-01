const std = @import("std");

const FileStructure= struct {
    pub const FS_Config = struct {
        root_dir: [:0]const u8,
        dir: []const u8,
        files: []const [] const u8,
    };

    const Self = @This();
    dir: []const u8,
    files: []const [] const u8,

    fn init(config: FS_Config) !Self{
        var buffer: [4094]u8 = undefined;
        const full_path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{config.root_dir, config.dir});

        return Self{
            .dir = full_path, 
            .files = config.files,
        };
    }
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;

    var stdin_buffer: [512]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);
    const reader = &stdin.interface;

    const root_dir = args.next() orelse return error.NoRootPath;
    const protiens = try FileStructure.init(.{
        .root_dir = root_dir,
        .dir = "/src/Protiens/",
        .files = &[_][]const u8{
            "Beans",
            "Steak",
            "Peanutbutter",
        },
    });

    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.writeAll("\nChoose a food file: \n");
    try writer.flush();

    for(protiens.files, 0..) |file, i| {
        var buffer: [512]u8 = undefined;
        const option = try std.fmt.bufPrint(&buffer, "[{d}] {s}", .{i, file});
        try writer.print("{s}\n", .{option});
        try writer.flush();
    }

    if(reader.takeDelimiterExclusive('\n')) |line| {
        const int_result = try std.fmt.parseInt(usize, line, 10);
        var buffer: [512]u8 = undefined;

        var file: []const u8 = undefined;

        switch(int_result) {
            0 => {
                file = protiens.files[0];
            },
            1 => {
                file = protiens.files[1];
            },
            2 => {
                file = protiens.files[2];
            },
            else => {return error.InvalidAnswer; }
        }
        
        const full_path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{protiens.dir, file});
        try writer.print("{s}\n", .{full_path});
        try writer.flush();
    } else |err| {
        switch(err) {
            error.EndOfStream => {},
            else => { return err; },
        }
    }
}

