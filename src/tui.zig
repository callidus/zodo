const std = @import("std");
const sys = std.os.system;

const outputBufferSz = 1024;
var outputBuffer: [outputBufferSz]u8 = undefined;
var outputBufferFill: usize = 0;
var origTermios: std.os.termios = undefined;

pub const IoCtlError = error{
    FileSystem,
    InterfaceNotFound,
} || std.os.UnexpectedError;

pub const Colour = enum(u32) {
    FG_BLACK = 30,
    FG_RED = 31,
    FG_GREEN = 32,
    FG_YELLOW = 33,
    FG_BLUE = 34,
    FG_MAGENTA = 35,
    FG_CYAN = 36,
    FG_WHITE = 37,
    FG_DEFAULT = 39,
    BG_BLACK = 40,
    BG_RED = 41,
    BG_GREEN = 42,
    BG_YELLOW = 43,
    BG_BLUE = 44,
    BG_MAGENTA = 45,
    BG_CYAN = 46,
    BG_WHITE = 47,
    BG_DEFAULT = 49,
};

pub const ColourMod = enum(u32) {
    NONE = 0,
    BOLD = 1,
    LOW = 2,
};

// build a colour
pub fn buildColour(a: Colour, b: ColourMod) u32 {
    return (@enumToInt(a) << 2) | @enumToInt(b);
}

// set a colour
pub fn setColour(col: u32) void {
    var buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "\x1b[{}m\x1b[{}m", .{ 0x00000002 & col, col >> 2 }) catch {
        unreachable;
    };
    output(out);
}

// buffered output
pub fn output(data: []const u8) void {
    var len = std.math.min(outputBuffer.len - outputBufferFill, data.len);
    var buf = outputBuffer[outputBufferFill..];
    _ = std.fmt.bufPrint(buf, "{s}", .{data[0..len]}) catch {
        unreachable;
    };
    outputBufferFill += len;

    if (len < data.len) {
        flush();
        output(data[len..]);
    }
}

const tempBufferSz = 128;
var tempBuffer: [tempBufferSz]u8 = undefined;

pub fn outputFmt(comptime fmt: []const u8, args: anytype) !void {
    var fbs = std.io.fixedBufferStream(&tempBuffer);
    try std.fmt.format(fbs.writer(), fmt, args);
    output(fbs.getWritten());
}

pub fn flush() void {
    _ = sys.write(sys.STDOUT_FILENO, outputBuffer[0..], outputBufferFill);
    outputBufferFill = 0;
}

// see https://github.com/ziglang/zig/issues/12961
pub fn ioctl(fd: sys.fd_t, request: u32, arg: usize) IoCtlError!void {
    while (true) {
        switch (sys.getErrno(sys.ioctl(fd, request, arg))) {
            .SUCCESS => return,
            .INVAL => unreachable, // Bad parameters.
            .NOTTY => unreachable,
            .NXIO => unreachable,
            .BADF => unreachable, // Always a race condition.
            .FAULT => unreachable, // Bad pointer parameter.
            .INTR => continue,
            .IO => return error.FileSystem,
            .NODEV => return error.InterfaceNotFound,
            else => |err| return std.os.unexpectedErrno(err),
        }
    }
}

// get the size of the terminal window hosting this process
pub fn getWinSz() sys.winsize {
    var ws = sys.winsize{
        .ws_col = 0,
        .ws_row = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    ioctl(sys.STDOUT_FILENO, sys.T.IOCGWINSZ, @ptrToInt(&ws)) catch {
        // FIXME: want to use perror here .....
        unreachable;
    };
    return ws;
}

// turn on "raw mode" for the terminal
pub fn enableRawMode() void {
    origTermios = std.os.tcgetattr(sys.STDIN_FILENO) catch {
        unreachable; // FIXME: do somthing smart here
    };

    var raw = origTermios;
    raw.lflag &= ~(sys.ECHO | sys.ICANON | sys.IEXTEN | sys.ISIG);
    raw.iflag &= ~(sys.BRKINT | sys.ICRNL | sys.INPCK | sys.ISTRIP | sys.IXON);
    raw.oflag &= ~(sys.OPOST);
    raw.cflag |= sys.CS8;

    std.os.tcsetattr(sys.STDIN_FILENO, sys.TCSA.FLUSH, raw) catch {
        unreachable; // FIXME: do smart stuff here
    };

    output("\x1b[?25l"); // hide cursor
}

// turn off "raw mode" for the terminal, return to default state
pub fn disableRawMode() void {
    setColour(buildColour(Colour.FG_DEFAULT, ColourMod.NONE));
    setColour(buildColour(Colour.BG_DEFAULT, ColourMod.NONE));

    output("\x1b[2J"); // clear screen
    output("\x1b[?25h"); // show cursor
    output("\x1b[0m"); // clear graphics flags
    output("\x1b[?25h"); // show cursor
    output("\x1b[H"); // home
    flush();

    std.os.tcsetattr(sys.STDIN_FILENO, sys.TCSA.FLUSH, origTermios) catch {
        unreachable; // FIXME: do smart stuff here
    };
}

// position at origin, clear screen
pub fn clear() void {
    output("\x1b[1;1H\x1b[2J");
}

// are there built in errors I can use for this stuff?
pub const IoError = error{
    IoErrorWriteFailed, // could not write
    IoErrorReadFailed, // could not read
};

pub const KeyName = enum(u32) {
    KEY_UNKNOWN = 1000,
    KEY_ARROW_LEFT,
    KEY_ARROW_RIGHT,
    KEY_ARROW_UP,
    KEY_ARROW_DOWN,
    KEY_DEL,
    KEY_HOME,
    KEY_END,
    KEY_PAGE_UP,
    KEY_PAGE_DOWN,
};

// read in a key press, return an integer value (possibly a member of KeyName enum)
pub fn readKey() IoError!u32 {
    var c: [3]u8 = undefined;
    while (true) {
        var x = sys.read(sys.STDIN_FILENO, c[0..], 1);
        if (x != 1) {
            if (sys.getErrno(x) == sys.E.AGAIN) {
                continue;
            }
            return IoError.IoErrorReadFailed;
        }
        break;
    }

    if (c[0] == '\x1b') {
        var x = sys.read(sys.STDIN_FILENO, c[1..], 2);
        if (x != 2) {
            return c[0];
        }

        if (std.mem.eql(u8, &c, "\x1b[A")) return @enumToInt(KeyName.KEY_ARROW_UP);
        if (std.mem.eql(u8, &c, "\x1b[B")) return @enumToInt(KeyName.KEY_ARROW_DOWN);
        if (std.mem.eql(u8, &c, "\x1b[C")) return @enumToInt(KeyName.KEY_ARROW_RIGHT);
        if (std.mem.eql(u8, &c, "\x1b[D")) return @enumToInt(KeyName.KEY_ARROW_LEFT);
        if (std.mem.eql(u8, &c, "\x1b[H")) return @enumToInt(KeyName.KEY_HOME);
        if (std.mem.eql(u8, &c, "\x1b[4")) return @enumToInt(KeyName.KEY_END);
        if (std.mem.eql(u8, &c, "\x1b[5")) return @enumToInt(KeyName.KEY_PAGE_UP);
        if (std.mem.eql(u8, &c, "\x1b[6")) return @enumToInt(KeyName.KEY_PAGE_DOWN);
        if (std.mem.eql(u8, &c, "\x1b[P")) return @enumToInt(KeyName.KEY_DEL);

        //std.debug.print("got '{c}' '{c}' '{c}'\n", .{ c[0], c[1], c[2] });
    }

    return c[0];
}
