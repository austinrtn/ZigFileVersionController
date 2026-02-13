const std = @import("std");
const JsonEntry = @import("JsonEntry.zig").JsonEntry;

const CACHE_FILE_NAME = "src/temp_cache.json";
const DIRECTORIES = [_][]const u8{
    "src/Fruits",
    "src/Grains",
    "src/Protiens",
};
const BLACKLIST = [_][]const u8{
    "src/Fruits/Apple",
};

//*****************************
// JSON VERSION CONTROL UPDATER
// *****************************
// This program writes json files that 
// keep track of updating versions of files within a project.
//
// When the program is ran: 
// 1)   A cache json file is created if it doesn't exist already.  If it does exist, the 
//      json is parsed and saved into VersionControlCacheUpdater.new_entries
//
// 2)   All files from all of the sub-directories the user added in the 'DIRECTORIES' slice are iterated through.
//      The files current hashed contents is compared to the cached hashed contents in cache.json, excluding files listed in the 'BLACKLIST' slice.
//
// 3a)  If the file's cached hashed content is equal to the file's current hash, no modification to the file have been made since the last
//      time this program was ran and the cached file version stays the same. 
//
// 3b)  If the file's cached hashed content is not equal to the file's current hash, this mean the file has been modified since the last time
//      this version was ran.  The cache stores the file's current hash and the cached version number is updated.
//
// 4)   Once all files in all listed directories have been iterated through and updated as necessary, the cache.json file is overwritten 
//      with the new, updated entries.

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    
    //ALLOCATOR
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //STDOUT INTERFACE
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;

    //GET ROOT PATH / DIRECTORY
    const ROOT_PATH = args.next() orelse return error.NoRootPath;

    //Clear Screen
    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.flush();

    //INIT INTERFACE
    var cache_updater = try VersionControlCacheUpdater.init(gpa_allocator, CACHE_FILE_NAME, ROOT_PATH, &DIRECTORIES);
    defer cache_updater.deinit();

    if(BLACKLIST.len > 0){
        try cache_updater.setBlacklist(&BLACKLIST);
    }

    // UPDATE INTERFACE AND GET NEW/MODDED FILES
    try cache_updater.updateVersionControl();
    const files = try cache_updater.flush();
    const total_files_moded = files.modified.len + files.new.len;
    
    // PRINT ANY CHANGES TO CACHCE
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

const VersionControlCacheUpdater = struct {
    pub const Self = @This();

    arena_allocator: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    cache_file: std.fs.File,
    cache_file_name: []const u8,

    root_dir: *std.fs.Dir,
    dirs: []const []const u8,
    blacklist: ?std.StringHashMap(void) = null,

    reader_buf: [1024*1024]u8 = undefined,
    json_scanner: ?std.json.Scanner = null, 

    entries: ?std.json.Value = null,
    new_entries: std.json.ObjectMap = undefined, 
    modified_files: std.ArrayList([]const u8) = undefined,
    new_files: std.ArrayList([]const u8) = undefined,
    
    /// Create new instance of VersionControlCacheUpdater
    fn init(gpa: std.mem.Allocator, file_name: []const u8, root_path: []const u8, dirs: []const []const u8) !Self {
        // Create arean allocator 
        const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena_ptr.allocator();

        // Create project directory
        const root_dir_ptr = try gpa.create(std.fs.Dir);
        root_dir_ptr.* = try std.fs.cwd().openDir(root_path, .{});

        // Open file if it exist open it, if not create a new one
        const file = blk: {
            const cache_file = root_dir_ptr.openFile(file_name, .{.mode = .read_write});

            if(cache_file) |file| {
                break :blk file;
            } else |err| {
                if(err == error.FileNotFound) {
                    const new_file = try root_dir_ptr.createFile(file_name, .{.read = true}); 
                    break :blk new_file;
                }
                else { return err; }
            }
        };

        var self = Self{
            .cache_file= file,
            .cache_file_name= file_name,
            .root_dir = root_dir_ptr,
            .dirs = dirs,

            .arena_allocator = arena_ptr,
            .allocator = allocator,
        };

        self.new_entries = std.json.ObjectMap.init(allocator);
        self.modified_files = std.ArrayList([]const u8){};

        return self;
    }

    fn deinit(self: *Self) void {
        const child_alloc = self.arena_allocator.child_allocator;

        self.cache_file.close();
        self.modified_files.deinit(self.allocator);
        self.new_files.deinit(self.allocator);
        self.new_entries.deinit();
        self.root_dir.close();

        if(self.json_scanner) |*scanner| {
            scanner.deinit();
        }
        if(self.blacklist) |*blacklist| {
            blacklist.deinit();
        }
            
        self.arena_allocator.deinit();
        child_alloc.destroy(self.root_dir);
        child_alloc.destroy(self.arena_allocator);
    }

    /// Creates a json object using contents of a JsonEntry instance 
    fn createObjMap(self: *Self, entry: JsonEntry) !std.json.ObjectMap{
        var obj_map= std.json.ObjectMap.init(self.allocator);
        try obj_map.put("dir", .{.string = entry.dir});
        try obj_map.put("file", .{.string = entry.file});
        try obj_map.put("full_path", .{.string = entry.full_path});
        try obj_map.put("hash", .{.string = entry.hash});
        try obj_map.put("version", .{.integer = @intCast(entry.version)});

        return obj_map; 
    }

    /// Reads cache.json file contents and parses existing JSON
    fn parseCacheToJson(self: *Self) !void {
        try self.cache_file.seekTo(0);
        var file_size = (try self.cache_file.stat()).size;

        // If file size is too small, write a new file with empty json object map  
        if(file_size < 2) {
            var buf: [64]u8 = undefined;
            var writer = self.cache_file.writer(&buf);
            try writer.interface.writeAll("{\n\n}");
            try writer.interface.flush();

            try self.cache_file.seekTo(0);
            file_size = (try self.cache_file.stat()).size;
        }

        // Read the file and get its contents for parsing 
        var reader = self.cache_file.reader(&self.reader_buf);
        try reader.interface.fill(file_size);
        const content = try reader.interface.readAlloc(self.allocator, file_size);

        // Parse file contents via json.Scanner
        self.json_scanner = std.json.Scanner.initCompleteInput(self.allocator, content);
        const parsed = try std.json.parseFromTokenSource(std.json.Value, self.allocator, &self.json_scanner.?, .{});

        self.entries = parsed.value;
    }

    /// Check if files have been modfied or created since cache was last updated. 
    /// Update file version accordingly and stage changes to cache.  
    /// Run VersionControlCacheUpdater.flush to write changes to file
    fn updateVersionControl(self: *Self) !void {
        try self.parseCacheToJson();
        const entries = self.entries.?.object;

        // Iterate through directories
        for(self.dirs) |dir_name| {
            var dir = blk: {
                if(self.root_dir.access(dir_name, .{})) {
                    break :blk try self.root_dir.openDir(dir_name, .{.iterate = true});
                } 
                break :blk try self.root_dir.makeDir(dir_name);
            };            
            defer dir.close();
            var dir_iterator = dir.iterate();

            // Iterate through files within directory
            while(try dir_iterator.next()) |src_file| {
                if(src_file.kind != .file) continue;
                const file_name = try self.allocator.dupe(u8, src_file.name);
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{dir_name, file_name});

                // Check if file is blacklisted, if so ignore it and 
                // continue to next file
                if(self.blacklist) |blacklist| {
                    if(blacklist.get(full_path)) |_| continue;
                }

                // Open source file and get size 
                var file = try self.root_dir.openFile(full_path, .{});
                defer file.close();
                const file_size = (try file.stat()).size;

                // Store contents of file 
                var content_buffer: [1024 * 1024]u8 = undefined;
                var reader = file.reader(&content_buffer);
                const content = try reader.interface.readAlloc(self.allocator, file_size);

                // Hash contents 
                const src_hash_int = std.hash.Wyhash.hash(0, content);
                const src_hash = try std.fmt.allocPrint(self.allocator, "{d}", .{src_hash_int}); 

                // Initalize a json entry that will later be converted into a JSON object map
                var json_entry = JsonEntry{.file = file_name, .dir = dir_name, .full_path = full_path, .hash = src_hash, .version = 0};

                // If there already exist the source file's meta data within cache.json
                if(entries.get(full_path)) |entry| {
                    var obj = entry.object; 
                     
                    // Get the cached mtime and version number from cache.json 
                    const hash_obj = obj.get("hash") orelse return error.MissingField;
                    const version_obj = obj.get("version") orelse return error.MissingField;

                    var hash = hash_obj.string;
                    var version: usize = @intCast(version_obj.integer);

                    // Compare the source file's mtime to file's cached mtime.
                    // Update cached mtime and increase the version if different
                    if(!std.mem.eql(u8, hash, src_hash)) {
                        hash = src_hash;
                        version += 1;
                        try self.modified_files.append(self.allocator, full_path);
                    }
                    json_entry.hash = hash; 
                    json_entry.version = version;
                } else {
                    // If the file's metadata currently does NOT exist within
                    // cache.json (the file is newly added to the directory)
                    try self.new_files.append(self.allocator, full_path);
                }

                // Conver JsonEntry into json value and stage the entry
                const obj_map = try self.createObjMap(json_entry);
                const json_object = std.json.Value{.object = obj_map};
                try self.new_entries.put(full_path, json_object);
            }
        }
    }

    /// Write staged changes to file and return new/modfied names of files
    fn flush(self: *Self) !struct {modified: [][]const u8, new: [][]const u8} {
        // Overwrite the file completely
        const writeable_file = try self.root_dir.createFile(self.cache_file_name, .{}); 
        defer writeable_file.close();
        
        // Create file writer 
        var write_buf: [1024 * 1024]u8 = undefined;
        var writer = writeable_file.writer(&write_buf);
        const interface = &writer.interface;
        
        // Convert staged entries into json value 
        const json_value = std.json.Value{.object = self.new_entries};
        const json_entries = std.json.fmt(json_value, .{.whitespace = .indent_2});

        // Write to file with new entries
        try interface.print("{f}", .{json_entries});
        try interface.flush();

        // Return names of modified and newly created files
        return .{
            .modified = self.modified_files.items,
            .new = self.new_files.items,
        };
    }

    /// Enables blacklisted files
    fn setBlacklist(self: *Self, blacklist: []const []const u8) !void {
        self.blacklist = std.StringHashMap(void).init(self.allocator);

        for(blacklist) |path| {
            try self.blacklist.?.put(path, {});
        }
    }
};

