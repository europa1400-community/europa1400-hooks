const std = @import("std");
const windows = std.os.windows;

const kernel32 = struct {
    extern "kernel32" fn VirtualAllocEx(
        hProcess: windows.HANDLE,
        lpAddress: ?*anyopaque,
        dwSize: usize,
        flAllocationType: u32,
        flProtect: u32,
    ) callconv(.Stdcall) ?*anyopaque;

    extern "kernel32" fn VirtualFreeEx(
        hProcess: windows.HANDLE,
        lpAddress: *anyopaque,
        dwSize: usize,
        dwFreeType: u32,
    ) callconv(.Stdcall) windows.BOOL;

    extern "kernel32" fn WriteProcessMemory(
        hProcess: windows.HANDLE,
        lpBaseAddress: *anyopaque,
        lpBuffer: *const anyopaque,
        nSize: usize,
        lpNumberOfBytesWritten: ?*usize,
    ) callconv(.Stdcall) windows.BOOL;

    extern "kernel32" fn CreateRemoteThread(
        hProcess: windows.HANDLE,
        lpThreadAttributes: ?*anyopaque,
        dwStackSize: usize,
        lpStartAddress: windows.LPTHREAD_START_ROUTINE,
        lpParameter: *anyopaque,
        dwCreationFlags: u32,
        lpThreadId: ?*u32,
    ) callconv(.Stdcall) ?windows.HANDLE;

    extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.Stdcall) u32;

    pub const GetModuleHandleW = windows.kernel32.GetModuleHandleW;
    pub const GetProcAddress = windows.kernel32.GetProcAddress;
};

const CREATE_SUSPENDED: u32 = 0x00000004;
const CREATE_NEW_CONSOLE: u32 = 0x00000010;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} <GameExePath> <server.dll> <hook_*.dll> [...]\n", .{args[0]});
        return;
    }

    const target_exe = args[1];
    const server_dll = args[4];

    const wide_path = try utf16z(allocator, target_exe);
    defer allocator.free(wide_path);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: windows.PROCESS_INFORMATION = std.mem.zeroes(windows.PROCESS_INFORMATION);

    std.debug.print("[Injector] Launching process suspended: {s}\n", .{target_exe});

    try windows.CreateProcessW(
        wide_path,
        null,
        null,
        null,
        0,
        CREATE_SUSPENDED | CREATE_NEW_CONSOLE,
        null,
        null,
        &si,
        &pi,
    );

    defer cleanup(pi.hThread, pi.hProcess);

    injectDll(pi.hProcess, server_dll, allocator) catch |e| {
        std.debug.print("  Injection failed: {}\\n", .{e});
        return;
    };

    for (args[3..]) |hook| {
        injectDll(pi.hProcess, hook, allocator) catch |e| {
            std.debug.print("  Injection failed: {}\\n", .{e});
            return;
        };
    }

    std.debug.print("[Injector] Resuming process\n", .{});
    _ = kernel32.ResumeThread(pi.hThread);
}

fn injectDll(hProc: windows.HANDLE, dllPath: []const u8, allocator: std.mem.Allocator) !void {
    const wide = try utf16z(allocator, dllPath);
    defer allocator.free(wide);

    const len_bytes = wide.len * 2;
    const remote_mem = kernel32.VirtualAllocEx(hProc, null, len_bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remote_mem == null) return error.AllocFailed;

    const wrote = kernel32.WriteProcessMemory(hProc, remote_mem.?, wide.ptr, len_bytes, null);
    if (wrote == windows.FALSE) return error.WriteFailed;

    //  const mod_path_wide_array = std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll");

    const mod_path = try utf16z(allocator, "kernel32.dll");
    const mod_path_wide: windows.LPCWSTR = mod_path.ptr;
    //  const mod_path_wide: windows.LPCWSTR = &mod_path_wide_array[0];

    defer allocator.free(mod_path);

    const hModule = kernel32.GetModuleHandleW(mod_path_wide) orelse return error.ModuleNotFound;
    const loadLibW = kernel32.GetProcAddress(hModule, "LoadLibraryW") orelse return error.SymbolNotFound;

    const addr = @as(usize, @intFromPtr(loadLibW));
    const lp_start: windows.LPTHREAD_START_ROUTINE = @ptrFromInt(addr);

    const thread = kernel32.CreateRemoteThread(hProc, null, 0, lp_start, remote_mem.?, 0, null) orelse return error.RemoteThreadFailed;

    try windows.WaitForSingleObject(thread, windows.INFINITE);
    _ = windows.CloseHandle(thread);
    _ = kernel32.VirtualFreeEx(hProc, remote_mem.?, 0, MEM_RELEASE);
}

fn utf16z(allocator: std.mem.Allocator, str: []const u8) ![:0]u16 {
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, str);
    defer allocator.free(utf16);
    return try appendNullTerm(allocator, utf16);
}

fn appendNullTerm(allocator: std.mem.Allocator, data: []const u16) ![:0]u16 {
    var new = try allocator.alloc(u16, data.len + 1);
    std.mem.copyForwards(u16, new[0..data.len], data);
    new[data.len] = 0;
    return new[0.. :0];
}

fn cleanup(hThread: windows.HANDLE, hProc: windows.HANDLE) void {
    _ = windows.CloseHandle(hThread);
    _ = windows.CloseHandle(hProc);
}
