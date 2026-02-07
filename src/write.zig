const std = @import("std");

// What gets parsed to and from for JSON data
const JsonEntry = struct {
    dir: []const u8,
    file: []const u8,
    full_path: []const u8,

    mtime: i128 = 0,
    version: usize = 0,
};

const JsonInterface = struct {
    pub const Self = @This();

    arena_allocator: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    cache_file: std.fs.File,
    cache_file_name: []const u8,
    root_dir: *std.fs.Dir,
    dirs: []const []const u8,
    blacklist: ?[]const []const u8 = null,

    reader_buf: [1024*1024]u8 = undefined,
    json_scanner: ?std.json.Scanner = null, 

    entries: ?std.json.Value = null,
    new_entries: std.json.ObjectMap = undefined, 
    modified_files: std.ArrayList([]const u8) = undefined,
    new_files: std.ArrayList([]const u8) = undefined,
    
    fn init(gpa: std.mem.Allocator, file_name: []const u8, root_dir: *std.fs.Dir, dirs: []const []const u8) !Self {
        const file = try root_dir.openFile(file_name, .{});
        const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);

        const allocator = arena_ptr.allocator();

        var self = Self{
            .cache_file= file,
            .cache_file_name= file_name,
            .root_dir = root_dir,
            .dirs = dirs,

            .arena_allocator = arena_ptr,
            .allocator = allocator,
        };

        self.new_entries = std.json.ObjectMap.init(allocator);
        self.modified_files = std.ArrayList([]const u8){};

        return self;
    }

    fn deinit(self: *Self) void {
        self.cache_file.close();
        self.modified_files.deinit(self.allocator);
        self.new_files.deinit(self.allocator);
        self.new_entries.deinit();

        const child_alloc = self.arena_allocator.child_allocator;
            
        if(self.json_scanner) |*scanner| {
            scanner.deinit();
        }
        self.arena_allocator.deinit();
        child_alloc.destroy(self.arena_allocator);
    }

    fn createObjMap(self: *Self, entry: JsonEntry) !std.json.ObjectMap{
        // Create a JSON value from the entry data
        var obj_map= std.json.ObjectMap.init(self.allocator);
        try obj_map.put("dir", .{.string = entry.dir});
        try obj_map.put("file", .{.string = entry.file});
        try obj_map.put("mtime", .{.integer = @intCast(entry.mtime)});
        try obj_map.put("version", .{.integer = @intCast(entry.version)});

        return obj_map; 
    }

    fn setEntries(self: *Self) !void {
        try self.cache_file.seekTo(0);
        const file_size = (try self.cache_file.stat()).size;
        var reader = self.cache_file.reader(&self.reader_buf);
        try reader.interface.fill(file_size);

        const content = try reader.interface.readAlloc(self.allocator, file_size);

        self.json_scanner = std.json.Scanner.initCompleteInput(self.allocator, content);
        const parsed = try std.json.parseFromTokenSource(std.json.Value, self.allocator, &self.json_scanner.?, .{});

        self.entries = parsed.value;
    }

    fn updateVersionControl(self: *Self) !void {
        try self.setEntries();
        const entries = self.entries.?.object;

        for(self.dirs) |dir_name| {
            var dir = try self.root_dir.openDir(dir_name, .{.iterate = true});
            defer dir.close();

            var dir_iterator = dir.iterate();
            while(try dir_iterator.next()) |src_file| {
                if(src_file.kind != .file) continue;
                const file_name = try self.allocator.dupe(u8, src_file.name);
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{dir_name, file_name});
                
                if(self.blacklist) |blacklist| {
                    var blacklisted = false;
                    for(blacklist) |banned_file| {
                        if(std.mem.eql(u8, banned_file, full_path)) {
                            blacklisted = true;
                            break;
                        }
                    }
                    if(blacklisted) continue;
                }
            
                const src_file_mtime = (try self.root_dir.statFile(full_path)).mtime;

                var json_entry = JsonEntry{.file = file_name, .dir = dir_name, .full_path = full_path, .mtime = src_file_mtime, .version = 0};

                if(entries.get(full_path)) |*entry| {
                    var obj = entry.object; 
                     
                    const mtime_obj = obj.get("mtime") orelse return error.MissingField;
                    const version_obj = obj.get("version") orelse return error.MissingField;
                    
                    var mtime: i128 = @intCast(mtime_obj.integer);
                    var version: usize = @intCast(version_obj.integer);

                    if(src_file_mtime != mtime) {
                        mtime = src_file_mtime;
                        version += 1;
                        try self.modified_files.append(self.allocator, full_path);
                    }
                    json_entry.mtime = mtime; 
                    json_entry.version = version;
                } else {
                    try self.new_files.append(self.allocator, full_path);
                }

                const obj_map = try self.createObjMap(json_entry);

                const json_object = std.json.Value{.object = obj_map};
                try self.new_entries.put(full_path, json_object);
            }
        }
    }

    fn writeJsonToFile(self: *Self) !struct {modified: [][]const u8, new: [][]const u8} {
        const writeable_file = try self.root_dir.createFile(self.cache_file_name, .{}); 
        defer writeable_file.close();
        
        var write_buf: [1024 * 1024]u8 = undefined;
        var writer = writeable_file.writer(&write_buf);
        const interface = &writer.interface;
        
        const json_value = std.json.Value{.object = self.new_entries};
        const json_entries = std.json.fmt(json_value, .{.whitespace = .indent_2});

        try interface.print("{f}", .{json_entries});
        try interface.flush();

        return .{
            .modified = self.modified_files.items,
            .new = self.new_files.items,
        };
    }

    fn setBlacklist(self: *Self, blacklist: []const []const u8) void {
        self.blacklist = blacklist;
    }
};

//***************************
// FILE VERSION ID TRACKER
// **************************
// This script is a demo to keep track of 
// file versions by comparing by caching file metadata 
// and comparing cached file metadata to current file metadata, specifically 
// the data last modified.  
// If the date last modified of the cached file metadata does NOT match the 
// date last modified of the current file, then the version for that file is updated in the cache, 
// and the user is notifed.
//
// This demo will be extrapolated for Prescient to keep track of files that need to be updated so that
// only files that have been modified since the last version of Prescient get updated as opposed to 
// the entire engine 

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //STDOUT INTERFACE
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;

    //GET ROOT PATH / DIRECTORY
    const root_path = args.next() orelse return error.NoRootPath;
    var root_dir = try std.fs.cwd().openDir(root_path, .{});
    defer root_dir.close();

    //Clear Screen
    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.flush();

    var json_interface = try JsonInterface.init(gpa_allocator, "src/cache.json", &root_dir, &[_][]const u8{"src/Fruits", "src/Grains", "src/Protiens"});
    defer json_interface.deinit();

    //json_interface.setBlacklist(&[_][]const u8{"src/Fruits/Apple"});

    try json_interface.updateVersionControl();
    const files = try json_interface.writeJsonToFile();
    const total_files_moded = files.modified.len + files.new.len;
    
    if(total_files_moded > 0) {
        if(files.new.len > 0) {
            try writer.print("\n{} files created:\n", .{files.new.len});
            for(files.new) |file| {
                try writer.print("{s}\n", .{file});
            }

            try writer.flush();
        }

        if(files.modified.len > 0) {
            try writer.print("\n{} files modified:\n", .{files.modified.len});
            for(files.modified) |file| {
                try writer.print("{s}\n", .{file});
            }
            try writer.flush();
        }
    } else {
        try writer.writeAll("No files modified.\n");
        try writer.flush();
    }

    try writer.writeAll("\nEverything up to date!\n");
}
