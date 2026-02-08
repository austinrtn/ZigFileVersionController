const std = @import("std");

const REPO_URL = "https://raw.githubusercontent.com/austinrtn/FileCacheTest/refs/heads/master/";
const OLD_CACHE_PATH = "src/file_cache.json";
const TEMP_CACHE_PATH = "src/cache_temp.json";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();

    const ROOT_PATH = args.next() orelse return error.RootPathNotFound; 

    var root_dir = try std.fs.cwd().openDir(ROOT_PATH, .{});
    defer root_dir.close();

    var writer_buf: [1024 * 1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&writer_buf);
    const writer = &stdout.interface;

    var reader_buf: [1024 * 1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&reader_buf);
    const reader = &stdin.interface;

    //Clear Screen
    try writer.writeAll("\x1B[2J");
    try writer.writeAll("\x1B[H");
    try writer.flush();

    while(args.next()) |arg| {
        if(std.mem.eql(u8, "refresh", arg)) {
            std.debug.print("Deleting cache... updating all files\n", .{});
            root_dir.deleteFile(OLD_CACHE_PATH) catch |err| switch(err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    root_dir.access(OLD_CACHE_PATH, .{}) catch |err| switch(err) {
        error.FileNotFound => {
            var old_cache_file = try root_dir.createFile(OLD_CACHE_PATH, .{}); 
            defer old_cache_file.close();
            var buf: [64]u8 = undefined;
            var ocf_writer = old_cache_file.writer(&buf);
            try ocf_writer.interface.writeAll("{\n\n}");
            try ocf_writer.interface.flush();
        },
        else => return err,
    };

    try writer.writeAll("Initing Program...\n");
    try writer.flush();

    var temp_entries_map = std.StringArrayHashMap(JsonEntry).init(allocator); 
    defer temp_entries_map.deinit();

    var old_entries_map = std.StringArrayHashMap(JsonEntry).init(allocator);
    defer old_entries_map.deinit();

    var entries_to_update = std.ArrayList(JsonEntry){};
    defer entries_to_update.deinit(allocator);

    var deleted_files = std.ArrayList([]const u8){};
    defer deleted_files.deinit(allocator);

    var client_interface = try ClientInterface.init(allocator, ROOT_PATH, REPO_URL, TEMP_CACHE_PATH);
    defer client_interface.deinit();

    try writer.writeAll("Downloading comparison file...\n");
    try writer.flush();

    try client_interface.downloadTempCache();
    
    try writer.writeAll("Parsing cache...\n");
    try writer.flush();

    var old_cache_interface = try CacheFile.init(allocator, OLD_CACHE_PATH, ROOT_PATH);
    defer old_cache_interface.deinit();
    const old_entries = try old_cache_interface.parseAndStoreEntries();

    try writer.writeAll("Parsing tmp cache...\n");
    try writer.flush();

    var temp_cache_interface = try CacheFile.init(allocator, TEMP_CACHE_PATH, ROOT_PATH);
    defer temp_cache_interface.deinit();
    const temp_entries = try temp_cache_interface.parseAndStoreEntries();

    try writer.writeAll("Comparing Files...\n");
    try writer.flush();

    for(temp_entries) |entry| {
        try temp_entries_map.put(entry.full_path, entry);
    }

    for(old_entries) |entry| {
        try old_entries_map.put(entry.full_path, entry);
    }

    for(old_entries) |old_entry| {
        if(temp_entries_map.get(old_entry.full_path)) |temp_entry| {
            if(temp_entry.version != old_entry.version) try entries_to_update.append(allocator, old_entry);
        } else {
            try deleted_files.append(allocator, old_entry.full_path);
        }
    }

    for(temp_entries) |temp_entry| {
        if(old_entries_map.get(temp_entry.full_path)) |_| { continue; } else {
            try entries_to_update.append(allocator, temp_entry);
        }
    }

    var update_available = false;

    try writer.writeAll("\n");
    try writer.flush();

    if(entries_to_update.items.len > 0) {
        update_available = true;
        try writer.print("{} Files need updating:\n", .{entries_to_update.items.len});
        for(entries_to_update.items) |entry| {
            try writer.print("{s}\n", .{entry.full_path});
            try writer.flush();
        }
    }

    if(deleted_files.items.len > 0) {
        update_available = true;
        try writer.print("{} Files to be deleted:\n", .{deleted_files.items.len});
        for(deleted_files.items) |entry| {
            try writer.print("{s}\n", .{entry});
            try writer.flush();
        }
    }

    try writer.writeAll("\n\n");
    try writer.flush();

    if(update_available) {
        try writer.writeAll("Would you like to update? [y/n]\n");
        try writer.flush();

        while(true) {
            if(reader.takeDelimiterExclusive('\n')) |line| {
                if(line.len == 0) continue;
                reader.toss(1);
                
                const char = std.ascii.toLower(line[0]);
                if(line.len == 1 and (char == 'y' or char == 'n')) {
                    if(char == 'n') return;

                    try client_interface.downloadEntries(entries_to_update.items);
                    try client_interface.overwriteUpdatedFiles();
                    break;

                } else {
                    try writer.writeAll("Invalid input! Try again...\n\n");
                    try writer.flush();
                    continue;
                }
            } else |err| switch(err) {
                error.EndOfStream => break,
                else => return err,
            }
        }
    }
    else {
        try writer.writeAll("Everying up to date! No action needed.\n");
        try writer.flush();
    }

    try old_cache_interface.updateCache(temp_cache_interface.file_content);
    try root_dir.deleteFile(TEMP_CACHE_PATH);
}

const ClientInterface = struct {
    const Self = @This();

    arena_alloc: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    root_dir: *std.fs.Dir,

    client: *std.http.Client,
    repo_url: []const u8,
    cache_path: []const u8,

    success_files: std.ArrayList(struct{file_path: []const u8, content: []const u8}) = .{},
    failed_files: std.ArrayList([]const u8) = .{},

    fn init(
        gpa: std.mem.Allocator, 
        root_path: []const u8, 
        repo_url: []const u8,
        cache_path: []const u8,
        ) !Self {
        const arena_alloc_ptr = try gpa.create(std.heap.ArenaAllocator); 
        arena_alloc_ptr.* = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena_alloc_ptr.allocator();

        const root_dir_ptr = try allocator.create(std.fs.Dir);
        root_dir_ptr.* = try std.fs.cwd().openDir(root_path, .{});

        const client_ptr = try allocator.create(std.http.Client);
        client_ptr.* = std.http.Client{.allocator = allocator};

        const self: Self = .{
            .arena_alloc = arena_alloc_ptr,
            .allocator = allocator, 
            .repo_url = repo_url,
            .root_dir = root_dir_ptr,
            .cache_path = cache_path,
            .client = client_ptr,
        };
        
        return self;
    }

    fn deinit(self: *Self) void {
        const child_alloc = self.arena_alloc.child_allocator;

        self.success_files.deinit(self.allocator);
        self.failed_files.deinit(self.allocator);
        self.client.deinit();
        self.root_dir.close();
        self.allocator.destroy(self.root_dir);

        self.arena_alloc.deinit();
        child_alloc.destroy(self.arena_alloc);
    }

    fn downloadTempCache(self: *Self) !void {
        const temp_cache_url = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{self.repo_url, self.cache_path});
        const temp_cache_uri = try std.Uri.parse(temp_cache_url);
        
        const temp_cache_file = try self.root_dir.createFile(self.cache_path, .{});
        defer temp_cache_file.close();

        var redir_buf:[1024 * 1024]u8 = undefined;
        var response_buf:[1024 * 1024]u8 = undefined;
        var response_writer = temp_cache_file.writer(&response_buf);

        const result = try self.client.fetch(.{
            .location = .{.uri = temp_cache_uri},
            .method = .GET,
            .redirect_buffer = &redir_buf,
            .response_writer = &response_writer.interface,
        });

        try response_writer.interface.flush();
        if(result.status != .ok) return error.HttpRequest;
    }

    fn downloadEntries(self: *Self, entries: []const JsonEntry) !void {
        for(entries) |entry| {
            const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{self.repo_url, entry.full_path});
            const uri = try std.Uri.parse(url);

            const file = try self.root_dir.createFile("tmp", .{.read = true});
            defer file.close();

            var redir_buf:[1024 * 1024]u8 = undefined;
            var response_buf:[1024 * 1024]u8 = undefined;
            var response_writer = file.writer(&response_buf);

            const result = try self.client.fetch(.{
                .location = .{.uri = uri},
                .method = .GET,
                .redirect_buffer = &redir_buf,
                .response_writer = &response_writer.interface,
            });

            try response_writer.interface.flush();

            if(result.status == .ok) {
                try file.seekTo(0);
                const file_size = (try file.stat()).size;
                var content_buf: [1024 * 1024]u8 = undefined;
                var content_reader = file.reader(&content_buf);
                const content = try content_reader.interface.readAlloc(self.allocator, file_size);
                const content_dupe = try self.allocator.dupe(u8, content);

                try self.success_files.append(self.allocator, .{.file_path = entry.full_path, .content = content_dupe});

            } else {
                try self.failed_files.append(self.allocator, entry.full_path);
                return;
            }
        }
    }

    fn overwriteUpdatedFiles(self: *Self) !void {
        for(self.success_files.items) |entry| {
            var file = try self.root_dir.createFile(entry.file_path, .{});
            defer file.close();
            var buf: [1024 * 1024]u8 = undefined;
            var fw = file.writer(&buf);

            try fw.interface.print("{s}", .{entry.content});
            try fw.interface.flush();
        }

        for(self.failed_files.items) |file_path| {
            self.root_dir.deleteFile(file_path) catch |err| switch(err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
};

const CacheFile = struct {
    const Self = @This();

    arena_alloc: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    file: std.fs.File,
    file_content: []const u8 = undefined,

    json_entries: []JsonEntry = undefined,

    pub fn init(gpa: std.mem.Allocator, file_path: []const u8, root_dir_path: []const u8) !Self {
        const arena_alloc_ptr = try gpa.create(std.heap.ArenaAllocator);
        arena_alloc_ptr.* = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena_alloc_ptr.allocator();

        errdefer {
            arena_alloc_ptr.deinit();
            gpa.destroy(arena_alloc_ptr);
        }

        var root_dir = try std.fs.cwd().openDir(root_dir_path, .{});
        defer root_dir.close();
        
        const file = try root_dir.openFile(file_path, .{.mode = .read_write});

        const self: Self = .{
            .allocator = allocator, 
            .arena_alloc = arena_alloc_ptr,
            .file = file,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        const child_alloc = self.arena_alloc.child_allocator;
        self.file.close();

        self.arena_alloc.deinit();
        child_alloc.destroy(self.arena_alloc);
    }

    fn parseAndStoreEntries(self: *Self) ![]JsonEntry{
        var entries = std.ArrayList(JsonEntry){};
        defer entries.deinit(self.allocator);

        try self.file.seekTo(0);
        const file_size = (try self.file.stat()).size;

        var content_buf:[1024 * 1024]u8 = undefined;
        var content_reader = self.file.reader(&content_buf);
        const content = try content_reader.interface.readAlloc(self.allocator, file_size);

        var json_scanner = std.json.Scanner.initCompleteInput(self.allocator, content);
        defer json_scanner.deinit();

        const parsed = try std.json.parseFromTokenSource(std.json.Value, self.allocator, &json_scanner, .{});
        const main_entry_map = parsed.value.object;
        var entry_iter = main_entry_map.iterator();

        while(entry_iter.next()) |unformated_entry| {
            const entry_map = unformated_entry.value_ptr.*;
            const json_entry = try convertJsonMapToEntry(entry_map.object);
            try entries.append(self.allocator, json_entry); 
        }

        self.file_content = try self.allocator.dupe(u8, content);
        self.json_entries = try entries.toOwnedSlice(self.allocator);
        return self.json_entries;
    }

    fn convertJsonMapToEntry(json_obj: std.json.ObjectMap) !JsonEntry {
        const file_obj = json_obj.get("file") orelse return error.MissingJsonField;
        const file = file_obj.string;

        const dir_obj = json_obj.get("dir") orelse return error.MissingJsonField;
        const dir = dir_obj.string;

        const full_path_obj = json_obj.get("full_path") orelse return error.MissingJsonField;
        const full_path = full_path_obj.string;

        const hash_obj = json_obj.get("hash") orelse return error.MissingJsonField;
        const hash = hash_obj.string;

        const version_obj = json_obj.get("version") orelse return error.MissingJsonField;
        const version: usize = @intCast(version_obj.integer);

        return .{
            .file = file,
            .dir = dir,
            .full_path = full_path, 
            .hash = hash,
            .version = version,
        };
    }

    fn updateCache(self: *Self, file_content: []const u8) !void {
        var writer_buf: [1024 * 1024]u8 = undefined;
        var writer = self.file.writer(&writer_buf);

        try writer.interface.writeAll("");
        try writer.interface.flush();

        try writer.interface.print("{s}", .{file_content});
        try writer.interface.flush();
    }
};

pub const JsonEntry = struct {
    dir: []const u8,
    file: []const u8,
    full_path: []const u8,

    hash: []const u8,
    version: usize = 0,
};

