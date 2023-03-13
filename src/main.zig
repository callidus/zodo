const std = @import("std");
const sys = std.os.system;

pub const IoCtlError = error{
    FileSystem,
    InterfaceNotFound,
} || std.os.UnexpectedError;

// are there built in errors I can use for this stuff?
pub const IoError = error{
    IoErrorWriteFailed, // could not write
    IoErrorReadFailed, // could not read
};

const KeyName = enum(u32) {
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

const TokType = enum { DONE, PRIORITY, DATE, WORDS, CONTEXT, PROJECT };

const Token = struct {
    type: TokType,
    data: []const u8,
};

// a TODO task
const Task = struct {
    done: bool,
    priority: u32,
    commenced: []const u8,
    completed: []const u8,
    tokens: std.ArrayList(Token),
};

// global state struct
const State = struct {
    rows: u32,
    cols: u32,
    offset: u32,
    highlight: u32,
    origTermios: std.os.termios,
    buffer: [1024]u8,
    bufFill: usize,
    tasks: std.ArrayList(Task),
};

// global state instance
var state = State{
    .rows = 0,
    .cols = 0,
    .offset = 0,
    .highlight = 0,
    .origTermios = undefined,
    .buffer = undefined,
    .bufFill = 0,
    .tasks = undefined,
};

// -- stuff for colours

const Colour = enum(u32) {
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

const ColourMod = enum(u32) {
    NONE = 0,
    BOLD = 1,
    LOW = 2,
};

// build a colour
fn buildColour(a: Colour, b: ColourMod) u32 {
    return (@enumToInt(a) << 2) | @enumToInt(b);
}

// set a colour
fn setColour(col: u32) void {
    var buf: [32]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "\x1b[{}m\x1b[{}m", .{ 0x00000002 & col, col >> 2 }) catch {
        unreachable;
    };
    output(out);
}

// --

// buffered output
fn output(data: []const u8) void {
    var len = std.math.min(state.buffer.len - state.bufFill, data.len);
    var buf = state.buffer[state.bufFill..];
    _ = std.fmt.bufPrint(buf, "{s}", .{data[0..len]}) catch {
        unreachable;
    };
    state.bufFill += len;

    if (len < data.len) {
        flush();
        output(data[len..]);
    }
}

fn flush() void {
    _ = sys.write(sys.STDOUT_FILENO, state.buffer[0..], state.bufFill);
    state.bufFill = 0;
}

//

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
fn getWinSz() sys.winsize {
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
fn enableRawMode() void {
    state.origTermios = std.os.tcgetattr(sys.STDIN_FILENO) catch {
        unreachable; // FIXME: do somthing smart here
    };

    var raw = state.origTermios;
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
fn disableRawMode() void {
    setColour(buildColour(Colour.FG_DEFAULT, ColourMod.NONE));
    setColour(buildColour(Colour.BG_DEFAULT, ColourMod.NONE));

    output("\x1b[2J"); // clear screen
    output("\x1b[?25h"); // show cursor
    output("\x1b[0m"); // clear graphics flags
    output("\x1b[?25h"); // show cursor
    output("\x1b[H"); // home
    flush();

    std.os.tcsetattr(sys.STDIN_FILENO, sys.TCSA.FLUSH, state.origTermios) catch {
        unreachable; // FIXME: do smart stuff here
    };
}

// read in a key press, return an integer value (possibly a member of KeyName enum)
fn readKey() IoError!u32 {
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

fn display() void {
    var i: u32 = 0;
    output("\x1b[1;1H\x1b[2J"); // position at origin, clear screen

    for (state.tasks.items) |task| {
        output(if (i == state.highlight) ">" else " ");

        if (task.done) {
            setColour(buildColour(Colour.FG_WHITE, ColourMod.LOW));
        }

        for (task.tokens.items) |token| {
            if (!task.done) {
                switch (token.type) {
                    TokType.DONE => {},
                    TokType.PRIORITY => {},
                    TokType.DATE => {
                        setColour(buildColour(Colour.FG_YELLOW, ColourMod.NONE));
                    },
                    TokType.WORDS => {
                        setColour(buildColour(Colour.FG_DEFAULT, ColourMod.NONE));
                    },
                    TokType.CONTEXT => {
                        setColour(buildColour(Colour.FG_BLUE, ColourMod.NONE));
                    },
                    TokType.PROJECT => {
                        setColour(buildColour(Colour.FG_GREEN, ColourMod.NONE));
                    },
                }
            }
            output(token.data[0..std.math.min(state.cols - 2, token.data.len)]);
        }
        output("\r\n");
        setColour(buildColour(Colour.FG_DEFAULT, ColourMod.NONE));

        i += 1;
        if (i == state.rows) break;
    }
    flush();
}

// read in a file
fn readInputFile(path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const fileSize = stat.size;
    return try file.reader().readAllAlloc(alloc, fileSize);
}

// find in index of elem in slice (like std.mem.indexOf)
fn find(comptime T: type, slice: []const T, val: T) ?usize {
    return find: for (slice, 0..) |char, idx| {
        if (char == val) break :find idx;
    } else {
        return null;
    };
}

// parse line into task info
fn lineToTask(line: []const u8, alloc: std.mem.Allocator) !Task {
    var task = Task{
        .tokens = std.ArrayList(Token).init(alloc),
        .done = false,
        .priority = 'Z',
        .completed = "",
        .commenced = "",
    };

    var slice = line[0..];

    // look for done tag
    if (slice.len > 1 and slice[0] == 'x' and slice[1] == ' ') {
        slice = slice[2..];
        task.done = true;
    }

    // look for priority tag
    if (slice.len > 3 and slice[0] == '(' and slice[2] == ')' and slice[3] == ' ') {
        task.priority = slice[1];
        slice = slice[4..];
    }

    // look for completion date
    if (slice[0] == '[') {
        if (find(u8, slice, ']')) |end| {
            if (end < slice.len and slice[end + 1] == ' ') {
                task.completed = slice[0..end];
                slice = slice[end + 2 ..];
            }
        }
    }

    // look for commencement date
    if (slice[0] == '[') {
        if (find(u8, slice, ']')) |end| {
            if (end < slice.len and slice[end + 1] == ' ') {
                task.completed = slice[0..end];
                slice = slice[end + 2 ..];
            }
        }
    }

    // scan for context and project parts
    var start: usize = 0;
    var skip: usize = 0;
    for (slice, 0..) |char, idx| {
        if (skip != 0) {
            skip -= 1;
            continue;
        }

        var token = switch (char) {
            '@' => TokType.CONTEXT,  
            '+' =>TokType.PROJECT,
            else => TokType.DONE,
        };

        if(token != TokType.DONE ) {
            if (find(u8, slice[idx..], ' ')) |end| {
                try task.tokens.append(Token{
                    .data = slice[start..idx],
                    .type = TokType.WORDS,
                });

                try task.tokens.append(Token{
                    .data = slice[idx .. idx + end],
                    .type = token,
                });
                start = idx + end;
                skip = end;
            }
        }
    }

    if (start != slice.len) {
        try task.tokens.append(Token{
            .data = slice[start..],
            .type = TokType.WORDS,
        });
    }
    return task;
}

// split data into lines
fn parseLines(data: []const u8, alloc: std.mem.Allocator) !std.ArrayList(Task) {
    var tasks = std.ArrayList(Task).init(alloc);
    var readIter = std.mem.tokenize(u8, data, "\n");
    while (readIter.next()) |line| {
        var task = try lineToTask(line, alloc);
        try tasks.append(task);
    }
    return tasks;
}

fn updateLoop() void {
    var x: u32 = '0';
    while (x != 'q') {
        display();
        x = readKey() catch {
            unreachable; // TODO: smart stuff here
        };

        if (x >= @enumToInt(KeyName.KEY_UNKNOWN)) {
            switch (@intToEnum(KeyName, x)) {
                KeyName.KEY_UNKNOWN => {}, // ignore unknown keys
                KeyName.KEY_ARROW_LEFT => {
                    state.tasks.items[state.highlight].done = false;
                },
                KeyName.KEY_ARROW_RIGHT => {
                    state.tasks.items[state.highlight].done = true;
                },
                KeyName.KEY_ARROW_UP => {
                    state.highlight =
                        if (state.highlight == 0) state.highlight else state.highlight - 1;
                },
                KeyName.KEY_ARROW_DOWN => {
                    state.highlight =
                        if (state.highlight < state.tasks.items.len - 1) state.highlight + 1 else state.highlight;
                },
                KeyName.KEY_DEL => {},
                KeyName.KEY_HOME => {},
                KeyName.KEY_END => {},
                KeyName.KEY_PAGE_UP => {},
                KeyName.KEY_PAGE_DOWN => {},
            }
        }
    }
}

pub fn main() !void {
    if (std.os.argv.len == 1) {
        std.debug.print("usage: {s} path/to/todo.txt\n", .{std.os.argv[0]});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();
    var data = try readInputFile(std.mem.span(std.os.argv[1]), alloc);
    //var data = try readInputFile("./test.txt", alloc);
    defer alloc.free(data);

    state.tasks = try parseLines(data, alloc);
    defer state.tasks.deinit();

    enableRawMode();
    defer disableRawMode();

    var ws = getWinSz();
    state.cols = ws.ws_col;
    state.rows = ws.ws_row;

    updateLoop();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
