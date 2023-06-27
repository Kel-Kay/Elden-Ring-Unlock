const std = @import("std");
const win = @import("win32_import.zig");

const proc_name = win.L("start_protected_game.exe");
const mod_name = proc_name;

const fps_pattern = [_]?u8{ 0xC7, null, null, null, 0x88, 0x88, 0x3C, 0xEB };
const hz_pattern = [_]?u8{ 0xEB, null, 0xC7, null, null, 0x3C, 0x00, 0x00, 0x00, 0xC7, null, null, 0x01, 0x00, 0x00, 0x00 };
const cc_pattern = [_]?u8{ 0x33, 0xC9, 0xFF, 0x15, 0x28, 0xF9, 0xB7, 0x03 };

const fps_pattern_offset = 3;
const hz_pattern_offset_one = 5;
const hz_pattern_offset_two = 12;
const cc_pattern_offset = 2;
const cc_pattern_inst_length = 6;

const new_cap = 240.0;
const new_frametime: f32 = 1.0 / new_cap;

const failure = error{
    FailedToCreateSnapshot,
    FailedToFindModule,
    FailedToOpenProcess,
    FailedToRetrieveModuleInfo,
    FailedToFindPattern,
    FailedToFindProcess,
    FailedToCopyModule,
    FailedToWriteProcessMemory,
};

pub fn main() failure!void {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (snapshot == win.INVALID_HANDLE_VALUE) return failure.FailedToCreateSnapshot;
    defer _ = win.CloseHandle(snapshot);

    var proc_entry = std.mem.zeroes(win.PROCESSENTRY32W);
    proc_entry.dwSize = @sizeOf(win.PROCESSENTRY32W);

    var opt_proc_id: ?u32 = null;

    if (win.Process32FirstW(snapshot, &proc_entry) == win.TRUE) {
        var has_proc = true;
        while (has_proc) {
            if (stringEql(@ptrCast([*:0]const u16, &proc_entry.szExeFile), proc_name)) {
                opt_proc_id = proc_entry.th32ProcessID;
                break;
            }

            has_proc = win.Process32NextW(snapshot, &proc_entry) == win.TRUE;
        }
    }

    const proc_id = opt_proc_id orelse return failure.FailedToFindProcess;
    const opt_proc_handle = win.OpenProcess(0xFFFF, win.FALSE, proc_id);

    const proc_handle = if (opt_proc_handle != win.INVALID_HANDLE_VALUE) opt_proc_handle.? else return failure.FailedToOpenProcess;
    defer _ = win.CloseHandle(proc_handle);

    const mod_handle = try findModule(proc_handle, mod_name);
    const mod_size = try getModuleSize(proc_handle, mod_handle);

    const mod_copy = win.VirtualAlloc(null, mod_size, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE) orelse return failure.FailedToCopyModule;
    defer _ = win.VirtualFree(mod_copy, 0, win.MEM_RELEASE);

    _ = win.ReadProcessMemory(proc_handle, mod_handle, mod_copy, mod_size, null);

    const fps_pattern_ptr = try findPattern(&fps_pattern, mod_copy, mod_size);
    const hz_pattern_ptr = try findPattern(&hz_pattern, mod_copy, mod_size);
    const cc_pattern_ptr = try findPattern(&cc_pattern, mod_copy, mod_size);

    const fps_pattern_rel = @ptrToInt(fps_pattern_ptr) - @ptrToInt(mod_copy);
    const hz_pattern_rel = @ptrToInt(hz_pattern_ptr) - @ptrToInt(mod_copy);
    const cc_pattern_rel = @ptrToInt(cc_pattern_ptr) - @ptrToInt(mod_copy);

    const zero_dword = std.mem.zeroes(u32);
    const nop_array = [_]u8{0x90} ** cc_pattern_inst_length;

    var success = win.TRUE;
    success *= win.WriteProcessMemory(proc_handle, @intToPtr(*anyopaque, @ptrToInt(mod_handle) + fps_pattern_rel + fps_pattern_offset), &new_frametime, @sizeOf(f32), null);
    success *= win.WriteProcessMemory(proc_handle, @intToPtr(*anyopaque, @ptrToInt(mod_handle) + hz_pattern_rel + hz_pattern_offset_one), &zero_dword, @sizeOf(u32), null);
    success *= win.WriteProcessMemory(proc_handle, @intToPtr(*anyopaque, @ptrToInt(mod_handle) + hz_pattern_rel + hz_pattern_offset_two), &zero_dword, @sizeOf(u32), null);
    success *= win.WriteProcessMemory(proc_handle, @intToPtr(*anyopaque, @ptrToInt(mod_handle) + cc_pattern_rel + cc_pattern_offset), &nop_array, @sizeOf(@TypeOf(nop_array)), null);

    return if (success == win.FALSE) failure.FailedToWriteProcessMemory;
}

fn findPattern(pattern: []const ?u8, mem_ptr: *anyopaque, mem_len: usize) failure!*anyopaque {
    var i: usize = 0;
    while (i < (mem_len - pattern.len)) : (i += 1) {
        var found: bool = true;

        var n: usize = 0;
        while (n < pattern.len) : (n += 1) {
            if (pattern[n]) |p_byte| {
                const byte: u8 = @ptrCast([*]u8, mem_ptr)[i + n];
                if (byte != p_byte) {
                    found = false;
                    break;
                }
            }
        }

        if (found) return @intToPtr(*anyopaque, @ptrToInt(mem_ptr) + i);
    }

    return failure.FailedToFindPattern;
}

fn findModule(process_handle: *anyopaque, name: [*:0]const u16) failure!*anyopaque {
    const buffer_size: usize = 1024;

    var module_data: [buffer_size]win.HMODULE = std.mem.zeroes([buffer_size]win.HMODULE);
    var data_size: c_ulong = 0;

    const success = win.K32EnumProcessModules(process_handle, &module_data, buffer_size * @sizeOf(win.HMODULE), &data_size);

    var name_buffer: [buffer_size:0]u16 = undefined;

    if (success != 0) {
        for (module_data) |optional_module| {
            if (optional_module) |module| {
                name_buffer = std.mem.zeroes([buffer_size:0]u16);
                _ = win.K32GetModuleBaseNameW(process_handle, module, &name_buffer, @truncate(c_ulong, buffer_size));
                if (stringEql(name, &name_buffer)) {
                    return module;
                }
            } else {
                break;
            }
        }
    }

    return error.FailedToFindModule;
}

fn getModuleSize(proc_handle: *anyopaque, mod_handle: *anyopaque) failure!u32 {
    var mod_info: win.MODULEINFO = undefined;
    const success = win.K32GetModuleInformation(proc_handle, @ptrCast(win.HMODULE, @alignCast(@alignOf(win.HMODULE), mod_handle)), &mod_info, @sizeOf(win.MODULEINFO));

    return if (success == win.FALSE) failure.FailedToRetrieveModuleInfo else mod_info.SizeOfImage;
}

fn stringEql(s1: [*:0]const u16, s2: [*:0]const u16) bool {
    var index: usize = 0;
    var match = s1[index] == s2[index];

    while (match and s1[index] != 0) {
        index += 1;
        match = s1[index] == s2[index];
    }

    return match;
}
