## Zig File Version Controller and Updater
This program allows users to keep track and cache file versions within a repository or server, and allows users to download the latest versions of the version controlled files into their project directory.  The repository owners select which files should be tracked by the version controller, and those using selected

### Use Case
This was created primarily for frameworks and the projects that use them.  I'm currently building a framework that can't be directly cloned, and not all files are relevant to the user using the framework.  This allows users to isolate only the files that need to be downloaded by those using the framework, and to update files incrementally as needed, without cloning the project or giving access to other, non-selected files.

### Setup
###### Project Owner:
Download the `version-ctrl-cacher.zig` file and add it to `src` directory in your project folder.  Then copy and paste this towards the bottom of your `build.zig` file:

``` zig
    const update_cache_exe= b.addExecutable(.{
        .name = "Update_Cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/vc_cacher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(update_cache_exe);
    const update_cache_step = b.step("vc-cache", "Update File Version Cache");
    const update_cache_cmd= b.addRunArtifact(update_cache_exe);
    update_cache_step.dependOn(&update_cache_cmd.step);
    update_cache_cmd.addArg(b.pathFromRoot("."));
    if(b.args) |args| update_cache_cmd.addArgs(args);
```

###### Remote Project User
Download the `vc_updater.zig` file and add it to `src` directory in your project folder.  Then copy and paste this towards the bottom of your `build.zig` file:

```zig
    const version_ctrl_exe = b.addExecutable(.{
        .name = "Version Control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("./src/vc_updater.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const version_ctrl_step = b.step("vc-update", "Download and overwrite out-of-date files");
    const version_ctrl_cmd = b.addRunArtifact(version_ctrl_exe);
    version_ctrl_step.dependOn(&version_ctrl_cmd.step);
    version_ctrl_cmd.addArg(b.pathFromRoot("."));
    if (b.args) |args| version_ctrl_cmd.addArgs(args);
```

### How to Use
###### Project owner:
Within the `vc_cacher.zig` file, select which files and directories you would like to add to the version-controller by adding the file / directory paths into the arrays at the top of the page.  You can also add files you want to be excluded from the version controller within the `BLACKLIST` variable.  It should be noted that sub-directories within selected directories will **NOT** be processed and will need to be added individually. 

```zig
const FILES = [_][]const u8 {
    "src/main.zig",
};
const DIRECTORIES = [_][]const u8{
    "src/Fruits",
    "src/Grains",
    "src/Grains/Pastas",
    "src/Proteins",
};
const BLACKLIST = [_][]const u8{
    "src/Fruits/Apple.txt",
};
```

Save changes, then exit the file and run `zig build vc-cache`.  This will produce a `temp_cache.json`.  This file is used to compare latest file versions to a remote user's local project.  Make sure that after running the command, the changes are committed to the repository / server hosting the files. 

###### Remote Project User
Within the `vc_updater.zig` file, set the `REPO_URL` variable to the main repository containing the `vc_cacher.zig` and `temp_cache.json` file.  Save changes, then exit the file and run `zig build vc-update`.  The `temp_cache.json` file will be downloaded from the main repository, and saved to local project as `local_cache.json`.  Users will then be asked to confirm download of any new or modified files.
###### CLI Usage:
`zig build vc-cacher` 
- Update Version Control cache within main repository.

`zig build vc-updater` 
- Download new / modified files from main repository to local project.

`zig build vc-updater -- refresh`
- Download latest versions of **ALL** files.  Recommended if files become corrupted or if error with the Version Controller.

`zig build vc-updater -- force`
- Bypass confirmation prompt, directly downloading all new / modified files.

`zig build vc-updater -- help`
- Get usage examples.