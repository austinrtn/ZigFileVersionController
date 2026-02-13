const std = @import("std");

const REPO_URL = "https://raw.githubusercontent.com/austinrtn/FileCacheTest/refs/heads/master/"; 
const LOCAL_CACHE_PATH = "src/local_cache.json";
const TEMP_CACHE_PATH = "src/temp_cache.json";

//*****************************
// JSON VERSION CONTROL MANAGER
// *****************************
//
// This tool is used in conjunction with the VersionControlCacheUpdater in ./update-cache.zig to update the 
// newest version of a file from it's online repository into a local project.  
//
// When the program is ran: 
// 1)   A json file of cached file metadata of files to be inluded within a project is downloaded from the REPO_URL.
//      This is the "temp_cache" file.  The repository should contain the latest versions of the project files.
//
// 2)   Both the temp_cache and local_cache JSON files are parsed and converted into a Zig readable struct called JsonEntry.
//      The JsonEntry instances are stored into a bidirectional data structure using hashmaps that enables easy comparison of 
//      entries.
//
// 3)   This temp_cache JsonEntries are compared to the local_cache JsonEntries to determine which files need updating or deleting.  
//      This determination is made by comparing files version between local and temp entries, as well as comparing which temp_cache entries 
//      exist in the local_cache file and vice-versa.
//      
// 4)   Files that are outdated or missing from the project are downloaded and written to disk.  Files that exist within the project but do not 
//      exist in the temp_cache file are deleted.  


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();

    //Get project path from build.zig. 
    //If RootPathNotFound error is returned, there is likely an error within the build.zig file 
    const ROOT_PATH = args.next() orelse return error.RootPathNotFound; 

    var version_controller = VersionController.init(.{
        .allocator = allocator,
        .local_cache_path = LOCAL_CACHE_PATH,
        .temp_cache_path = TEMP_CACHE_PATH,
        .root_dir_path = ROOT_PATH, 
        .repo_url = REPO_URL,
        .args = &args,
    }) catch |err| switch(err) {
        error.InvalidArg => return, // InvalidArg error retuns void with a warning to user
        error.ShowHelp => return, // User passed "help" arg, program should return before VersionController.run
        else => return err,
    };

    defer version_controller.deinit();
    try version_controller.run();
}

/// Handles all version control functionality: detecting chagnes between local and online repo,
/// downloading updated versions of files, and overwriting old outdated files.
const VersionController = struct {
    const Self = @This();

    // Parameter used for VersionController.init method
    const Config = struct {
        allocator: std.mem.Allocator,
        local_cache_path: []const u8, // Cache path in project directory
        temp_cache_path: []const u8, // Cache path downloaded from repo/server -- up to date cache 
        root_dir_path: []const u8, // Path of root directory
        repo_url: []const u8, // url of server / repo containing up to date files / cache 
        args: *std.process.ArgIterator, // Args from terminal / std.process.args
    };

    allocator: std.mem.Allocator,
    client_interface: *ClientInterface = undefined, //Downloads files
    
    local_cache_path: []const u8, 
    temp_cache_path: []const u8,
    root_dir: *std.fs.Dir,

    read_buf: [1024 * 8]u8 = undefined,
    write_buf: [1024]u8 = undefined, 

    stdin: std.fs.File.Reader = undefined, // used to get input from terminal
    stdout: std.fs.File.Writer = undefined, // used to print output to termianl 

    local_cache_file: ?*CacheFile = null, // CacheFile struct for local project cache
    temp_cache_file: ?*CacheFile = null, // CacheFile struct for newest versions of cache.  Gets deleted after program executed 
                                         
    local_cache_hash_map: ?std.StringHashMap(JsonEntry) = null, // Contains JsonEntries of local cached files 
    temp_cache_hash_map: ?std.StringHashMap(JsonEntry) = null, // Contains JsonEntries of updated cached files 

    entries_to_download: std.ArrayList(JsonEntry) = .{}, // Entries / files pending download
    new_entries: std.ArrayList(JsonEntry) = .{}, // Entries that do not exist locally that need to be downloaded 
    entries_to_update: std.ArrayList(JsonEntry) = .{}, // Entries that exist locally but need to be updated 
    entries_to_delete: std.ArrayList([]const u8) = .{}, // Entries that no longer exist in latest update and need to be deleted

    refresh: bool = false, // If true, "refresh" arg was passed by user, delete all linked files 
    force: bool = false, // If true, "force" arg was passed by user, and confrimation prompt will be skipped 
    help: bool = false, // If true, "help" arg was passed by user, and program should only print help text and terminate 

    /// Create VersionController instance
    pub fn init(config: Config) !Self {
        const allocator = config.allocator;

        // Create pointer for root directory struct 
        const root_dir_ptr = try allocator.create(std.fs.Dir); 
        root_dir_ptr.* = try std.fs.cwd().openDir(config.root_dir_path, .{});
        
        errdefer {
            root_dir_ptr.close();
            allocator.destroy(root_dir_ptr);
        }

        var self = Self{
            .allocator = allocator,
            .local_cache_path = config.local_cache_path,
            .temp_cache_path = config.temp_cache_path,
            .root_dir = root_dir_ptr,
        };

        // Create stdout / stdin for input / ouptput 
        const stdin = std.fs.File.stdin().reader(&self.read_buf);
        self.stdin = stdin;

        const stout = std.fs.File.stdout().writer(&self.write_buf);
        self.stdout = stout;
        try self.clearScreen();

        // Check if any args have been passed.  Make sure all args are valid. 
        if(!try self.handleArgs(config.args)) {
            allocator.destroy(root_dir_ptr);
            return error.InvalidArg;
        }

        if(self.help) return error.ShowHelp; 

        try self.setup();

        // Create pointer for local_cache_file  
        const local_cache_file_ptr = try allocator.create(CacheFile);
        local_cache_file_ptr.* = try CacheFile.init(allocator, config.local_cache_path, root_dir_ptr);
        self.local_cache_file = local_cache_file_ptr;

        errdefer {
            local_cache_file_ptr.deinit();
            allocator.destroy(local_cache_file_ptr);
        }

        // Create pointer for client_interface
        const client_ptr = try allocator.create(ClientInterface);
        client_ptr.* = try ClientInterface.init(allocator, root_dir_ptr, config.repo_url, config.temp_cache_path);
        self.client_interface = client_ptr;

        errdefer {
            client_ptr.deinit();
            allocator.destroy(client_ptr);
        }

        // init cache hash maps
        self.local_cache_hash_map = std.StringHashMap(JsonEntry).init(allocator);
        self.temp_cache_hash_map = std.StringHashMap(JsonEntry).init(allocator);

        errdefer {
            if(self.local_cache_hash_map) |local_map| local_map.deinit(); 
            if(self.temp_cache_hash_map) |temp_map| temp_map.deinit(); 
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.client_interface.deinit();
        if(self.local_cache_file) |local_file| local_file.deinit();
        if(self.temp_cache_file) |temp_file| temp_file.deinit();
        self.root_dir.close();

        self.new_entries.deinit(self.allocator);
        self.entries_to_update.deinit(self.allocator);
        self.entries_to_delete.deinit(self.allocator);
        self.entries_to_download.deinit(self.allocator);

        if(self.local_cache_hash_map) |*local_map| local_map.deinit();
        if(self.temp_cache_hash_map) |*temp_map| temp_map.deinit();

        self.allocator.destroy(self.root_dir);
        self.allocator.destroy(self.client_interface);
        if(self.local_cache_file) |local_file| self.allocator.destroy(local_file);
        if(self.temp_cache_file) |temp_file| self.allocator.destroy(temp_file);
    }

    /// Clear terminal contents 
    pub fn clearScreen(self: *Self) !void {
        try self.stdout.interface.writeAll("\x1B[2J");
        try self.stdout.interface.writeAll("\x1B[H");
        try self.stdout.interface.flush();
    }

    /// Read and apply args from command line 
    fn handleArgs(self: *Self, args: *std.process.ArgIterator) !bool{
        const writer = &self.stdout.interface;
        while(args.next()) |arg| {
            if(std.mem.eql(u8, "refresh", arg)){ self.refresh = true; } // Check `refresh` arg
            else if(std.mem.eql(u8, "force", arg)){ self.force = true; }// Check `force` arg
                                                                        //
            // Check help arg
            else if(std.mem.eql(u8, "help", arg)) {
                try writer.writeAll("\nCmd ussage: ");
                try writer.writeAll("\nzig build version-ctrl -- [args]");
                try writer.writeAll("\n\n-- force: Bypass confrimation prompt");
                try writer.writeAll("\n-- refresh: Delete and redownload all linked files");
                try writer.flush();
                self.help = true;
                return true;
            }

            else { // Check for invalid arguements
                try writer.print("Invalid arguement: {s}\nRun `zig build version-ctrl -- help` for more info.", .{arg});
                try writer.flush();
                return false;
            }
        }

        return true;
    }

    /// Prepare VersionController for downloading update 
    fn setup(self: *Self) !void {
        const writer = &self.stdout.interface;

        // Check if the local_cache file exist.  If not, create a new file with empty Json object
        self.root_dir.access(LOCAL_CACHE_PATH, .{}) catch |err| switch(err) {
            error.FileNotFound => {
                try writer.print("{s} not found.  Creating new file...\n", .{self.local_cache_path});
                try writer.flush();

                var local_cache_file = try self.root_dir.createFile(LOCAL_CACHE_PATH, .{}); 
                defer local_cache_file.close();
                var buf: [64]u8 = undefined;
                var ocf_writer = local_cache_file.writer(&buf);
                try ocf_writer.interface.writeAll("{\n\n}");
                try ocf_writer.interface.flush();
            },
            else => return err,
        };

    }

    /// Attempt update download and apply changes 
    fn run(self: *Self) !void {
        const writer = &self.stdout.interface;
        const reader = &self.stdin.interface;

        try writer.writeAll("Beginning update...\n");
        try writer.writeAll("Downloading comparison file...\n");
        try writer.flush();

        // Download temporary cache file containing newest versions 
        try self.client_interface.downloadTempCache();

        // Create CacheFile pointer for temp cache 
        const temp_cache_file_ptr = try self.allocator.create(CacheFile);
        temp_cache_file_ptr.* = try CacheFile.init(self.allocator, self.temp_cache_path, self.root_dir);
        self.temp_cache_file = temp_cache_file_ptr;

        try writer.writeAll("Parsing Json...\n");
        try writer.flush();

        // Get / parse JsonEntries from both local_cache and temp cache 
        const local_entries = if(self.local_cache_file) |local_file| (try local_file.parseAndStoreEntries()) else &[_]JsonEntry{};
        const temp_entries = if(self.temp_cache_file) |temp_file| (try temp_file.parseAndStoreEntries()) else &[_]JsonEntry{};

        try writer.writeAll("Comparing Files...\n");
        if(self.refresh) try writer.writeAll("[refresh] argument called.  Attempting full update...\n");
        try writer.writeAll("\n");
        try writer.flush();

        // Fill both hashmaps with JsonEntries
        if(self.local_cache_hash_map) |*local_map| {
            // If refresh arg passed, send empty array of JsonEntries.  This causes every entry on the temp file to be staged for download
            if (self.refresh) { try buildHashMap(local_map, &[_]JsonEntry{}); }
            else { try buildHashMap(local_map, local_entries); }
        }
        if(self.temp_cache_hash_map) |*temp_map| try buildHashMap(temp_map, local_entries);

        // Determine which files need to be updated / delteed 
        try self.compareEntries(local_entries, temp_entries);

        // If entries from local cache match temp_cache entries, 
        // no changes to file structure has been made and no update necessary 
        if(self.entries_to_download.items.len == 0 ) {
            try writer.writeAll("Everything up to date!...\n");
            try writer.flush();
            return;
        }

        if(self.force) { // Bypass confirmation
            try self.downloadEntries();
            if(try self.downloadFailed()) return; // Return if files fail to download
        } else {
            try writer.print("{} files available for update.  Confirm update? [y/n]\n", .{self.entries_to_download.items.len});
            try writer.flush();

            while(true) { // User confirmation to download updates
                if(reader.takeDelimiterExclusive('\n')) |line| {
                    reader.toss(1);
                    if(line.len == 0) continue;
                    const char = std.ascii.toLower(line[0]);

                    if(line.len == 1 and (char == 'y' or char == 'n')) {
                        if(char == 'n') {
                            try writer.writeAll("Refusing download, exiting application...");
                            return; 
                        }

                        else if(char == 'y') {
                            try self.downloadEntries(); 
                            if(try self.downloadFailed()) return; // Return if files fail to download
                            break;
                        }
                    } else {
                        try writer.writeAll("Invalid input\n"); 
                        try writer.flush();
                        continue;
                    }

                } else |err| switch(err){
                    error.EndOfStream => {},
                    else => return err,
                }
            }
        }

        try writer.writeAll("\n\nDownload Complete!");
        try writer.flush();

        try self.client_interface.overwriteUpdatedFiles(); // Overwrite new / modified files with updated file content 
                                                           
        if (self.temp_cache_file) |temp_file| if(self.local_cache_file) |local_file| {
            try local_file.updateCache(temp_file.file_content); // Overwrite local cache file to match temp_cache contents 
        };

        // Delete the temp cache file 
        if (self.temp_cache_file) |temp_file| if(self.local_cache_file) |local_file| {
            try local_file.updateCache(temp_file.file_content);
            try self.root_dir.deleteFile(self.temp_cache_path);
        };
    }

    /// Use ClientInterface to download added / modified files 
    fn downloadEntries(self: *Self) !void{
        const writer = &self.stdout.interface;
        try writer.writeAll("\nDownloading Files...\n───────────────────────────────────\n");
        try writer.flush();
        try self.client_interface.downloadEntries(self.entries_to_download.items, &self.stdout);
    }

    fn downloadFailed(self: *Self) !bool {
        const writer = &self.stdout.interface;

        if(self.client_interface.failed_files.items.len > 0) {
            try writer.writeAll("Failed to download files: \n");
            for(self.client_interface.failed_files.items) |file| {
                try writer.print("{s}\n", .{file});
            }
            try writer.writeAll("\nUpdate aborted due to failed files.\n");
            return true;
        }
        return false;
    }

    /// Fills hashmap with JsonEntry 
    fn buildHashMap(hash_map: *std.StringHashMap(JsonEntry), entries: []const JsonEntry) !void {
        for(entries) |entry| {
            try hash_map.put(entry.full_path, entry);
        }
    }

    /// Uses bidirectional hashmap structure to compare local cache file to temp cache file 
    /// to detect which files have been modified, created, or deleted in updated version
    fn compareEntries(self: *Self, local_entries: []const JsonEntry, temp_entries: []const JsonEntry) !void {
        const local_map = self.local_cache_hash_map orelse return error.HashMapNotInited;  
        const temp_map = self.temp_cache_hash_map orelse return error.HashMapNotInited;  

        for(local_entries) |local_entry| {
            if(temp_map.get(local_entry.full_path)) |temp_entry| {
                if(temp_entry.version != local_entry.version) {
                    try self.entries_to_update.append(self.allocator, local_entry);
                    try self.entries_to_download.append(self.allocator, temp_entry);
                }
            } else {
                try self.entries_to_delete.append(self.allocator, local_entry.full_path);
            }
        }

        for(temp_entries) |temp_entry| {
            if(local_map.get(temp_entry.full_path)) |_| {} else {
                try self.new_entries.append(self.allocator, temp_entry);
                try self.entries_to_download.append(self.allocator, temp_entry);
            }
        }
    }
};

/// Downloads and stores file contents from repository as well as temp_cache file 
const ClientInterface = struct {
    const Self = @This();

    arena_alloc: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    root_dir: *std.fs.Dir,

    client: *std.http.Client, // Zig tool for HTTP requests 
    repo_url: []const u8, // URL where file contents are downloaded from 
    cache_path: []const u8, // Where to store temp_cache file 
    downloaded_files: bool = false, // Flag for whether downloadEntries() has been ran

    success_files: std.ArrayList(struct{file_path: []const u8, content: []const u8}) = .{},
    failed_files: std.ArrayList([]const u8) = .{},

    /// Create ClientInterface instance 
    fn init(
        gpa: std.mem.Allocator, 
        root_dir: *std.fs.Dir,
        repo_url: []const u8,
        cache_path: []const u8,
        ) !Self {
        // Create Arena Allocator for easy clean up 
        const arena_alloc_ptr = try gpa.create(std.heap.ArenaAllocator); 
        arena_alloc_ptr.* = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena_alloc_ptr.allocator();

        // Create ClientInterface pointer 
        const client_ptr = try allocator.create(std.http.Client);
        client_ptr.* = std.http.Client{.allocator = allocator};

        const self: Self = .{
            .arena_alloc = arena_alloc_ptr,
            .allocator = allocator, 
            .repo_url = repo_url,
            .root_dir = root_dir,
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
        self.allocator.destroy(self.root_dir);

        self.arena_alloc.deinit();
        child_alloc.destroy(self.arena_alloc);
    }

    /// Downloads and writes to file temp_cache 
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
        if(result.status != .ok) {
            std.debug.print("Failed downloading cache file from repo: {s}/{s}\n", .{REPO_URL, TEMP_CACHE_PATH});
            std.debug.print("Make sure the name of TEMP_CACHE_PATH matches the TEMP_CACHE_PATH variable in update-cache.zig", .{});
            return error.HttpRequest;
        }
    }


    /// Sends HTTP requests to repo to download file contents.  
    /// Provides download status display 
    fn downloadEntries(self: *Self, entries: []const JsonEntry, stdout: *std.fs.File.Writer) !void {
        const interface = &stdout.interface;

        var loading_bar = [_][]const u8{" "} ** 10; // Create empty loading bar 
        try interface.writeAll("\r\x1b[k"); // Clear terminal line 
        try interface.writeAll("│");

        // Print emtpy loading bar 
        for(loading_bar) |char| {
            try interface.print("{s}", .{char});
        }

        // File status indicators: sucessful downloads, failed downloads, and files left to download 
        try interface.print("│ {}✔ │ {}⚠ │ {}⇩ │", .{self.success_files.items.len, self.failed_files.items.len, entries.len});
        try interface.flush();

        for(entries, 0..) |entry, i| {
            const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{self.repo_url, entry.full_path});
            const uri = try std.Uri.parse(url);

            // Create temporary file on disk that will store contents of file being downloaded 
            const file = try self.root_dir.createFile("tmp", .{.read = true});

            // Buffer to store file contents 
            var redir_buf:[1024 * 1024]u8 = undefined;
            var response_buf:[1024 * 1024]u8 = undefined;
            var response_writer = file.writer(&response_buf);

            // HTTP request 
            const result = try self.client.fetch(.{
                .location = .{.uri = uri},
                .method = .GET,
                .redirect_buffer = &redir_buf,
                .response_writer = &response_writer.interface,
            });

            try response_writer.interface.flush(); // Write contents of downloaded fo file 

            if(result.status == .ok) {
                try file.seekTo(0);
                const file_size = (try file.stat()).size;
                var content_buf: [1024 * 1024]u8 = undefined;
                var content_reader = file.reader(&content_buf);
                const content = try content_reader.interface.readAlloc(self.allocator, file_size); // Get contents of downloaded tmp file  
                const content_dupe = try self.allocator.dupe(u8, content);

                try self.success_files.append(self.allocator, .{.file_path = entry.full_path, .content = content_dupe});

            } else {
                try self.failed_files.append(self.allocator, entry.full_path);
            }

            file.close();
            try self.root_dir.deleteFile("tmp"); 
            
            // Update loading bar / status indicators 
            try interface.writeAll("\r\x1b[K");
            try interface.writeAll("│");

            const entries_len_f32: f32 = @floatFromInt(entries.len);
            const i_f32: f32 = @floatFromInt(i + 1);
            const percent_finished: f32 = i_f32 / entries_len_f32;
            const percent = (percent_finished * 10); 
            const percent_converted: usize = @intFromFloat(percent);

            for(0..percent_converted) |idx| {
                if(idx > loading_bar.len) break;
                loading_bar[idx] = "═";
            }

            for(loading_bar) |char| {
                try interface.print("{s}", .{char});
            }

            try interface.print("│ {}✔ │ {}⚠ │ {}⇩ │ {s} ", .{self.success_files.items.len, self.failed_files.items.len, entries.len - 1 - i, entry.file});
            try interface.flush();
            self.downloaded_files = true;
        }
    }

    // Overwrite local files with recently downloaded, udpated versions 
    fn overwriteUpdatedFiles(self: *Self) !void {
        if(!self.downloaded_files) return error.FilesNotDownloaded; 

        for(self.success_files.items) |entry| {
            var file = try self.root_dir.createFile(entry.file_path, .{}); // Create / overwrite file of downloaded entry.  
            defer file.close();
            var buf: [1024 * 1024]u8 = undefined;
            var fw = file.writer(&buf);

            try fw.interface.print("{s}", .{entry.content});
            try fw.interface.flush();
        }
    }
};

const CacheFile = struct {
    const Self = @This();

    arena_alloc: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    file: std.fs.File, // File struct containg cached file metadata in Json
    file_content: []const u8 = undefined,

    json_entries: []JsonEntry = undefined, // Parsed json converted into JsonEntry struct 

    /// Create CacheFile instance
    pub fn init(gpa: std.mem.Allocator, file_path: []const u8, root_dir: *std.fs.Dir) !Self {
        const arena_alloc_ptr = try gpa.create(std.heap.ArenaAllocator);
        arena_alloc_ptr.* = std.heap.ArenaAllocator.init(gpa);
        const allocator = arena_alloc_ptr.allocator();

        errdefer {
            arena_alloc_ptr.deinit();
            gpa.destroy(arena_alloc_ptr);
        }
        
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

    /// Parse Json from file and store them within *CacheFile.json_entries 
    fn parseAndStoreEntries(self: *Self) ![]JsonEntry{
        var entries = std.ArrayList(JsonEntry){};
        defer entries.deinit(self.allocator);

        try self.file.seekTo(0);
        const file_size = (try self.file.stat()).size;

        var content_buf:[1024 * 1024]u8 = undefined;
        var content_reader = self.file.reader(&content_buf);
        const content = try content_reader.interface.readAlloc(self.allocator, file_size); // Get file content 

        // zig tool to parse Json
        var json_scanner = std.json.Scanner.initCompleteInput(self.allocator, content);
        defer json_scanner.deinit();

        const parsed = try std.json.parseFromTokenSource(std.json.Value, self.allocator, &json_scanner, .{}); // Parse json from scanner
        const main_entry_map = parsed.value.object; // Convert json into zig readable object.  The entire file is a json object, 
                                                    // containing sub-objects which represent JsonEntry structs 
        var entry_iter = main_entry_map.iterator(); // object field iterator 

        // Iterate through Json objects and convert into JsonEntries
        while(entry_iter.next()) |unformated_entry| {
            const entry_map = unformated_entry.value_ptr.*;
            const json_entry = try convertJsonMapToEntry(entry_map.object);
            try entries.append(self.allocator, json_entry); 
        }

        // Save contents of json file
        self.file_content = try self.allocator.dupe(u8, content);
        self.json_entries = try entries.toOwnedSlice(self.allocator);
        return self.json_entries;
    }

    /// Convert JsonObject map from parsed JSON into JsonEntry zig struct 
    fn convertJsonMapToEntry(json_obj: std.json.ObjectMap) !JsonEntry {
        // Get indivdual fields 
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

/// Struct containing fields for CacheFile metadata.  
/// Used to convert JsonObjectMaps from parsed json file into zig readable struct 
pub const JsonEntry = struct {
    dir: []const u8,
    file: []const u8,
    full_path: []const u8,

    hash: []const u8,
    version: usize = 0,
};

