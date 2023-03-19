const std = @import("std");
const sys = std.os.system;
const tui = @import("tui");

const TokType = enum { DONE, PRIORITY, DATE, WORDS, CONTEXT, PROJECT };

const Token = struct {
    type: TokType,
    data: []const u8,
};

// a TODO task
const Task = struct {
    done: bool,
    hidden: bool,
    priority: u32,
    creationDate: []const u8,
    completionDate: []const u8,
    tokens: std.ArrayList(Token),
};

const BufError = error{
    NoSpace,
};

fn Buffer(comptime T: usize) type {
    return struct {
        memory: [T]u8,
        fill: usize,

        fn clear(self: *@This()) void {
            std.mem.set(u8, &self.memory, 0);
            self.fill = 0;
        }

        fn hasSpaceFor(self: *@This(), size: usize) bool {
            return self.memory.len - self.fill >= size;
        }

        fn getFreeSlice(self: *@This()) []u8 {
            return self.memory[self.fill..];
        }

        fn pushBytes(self: *@This(), data: []const u8) BufError!void {
            if (self.hasSpaceFor(data.len)) {
                std.mem.copy(u8, self.getFreeSlice(), data);
                self.fill += data.len;
                return;
            }
            return BufError.NoSpace;
        }
    };
}

fn buildBuffer(comptime T: usize) Buffer(T) {
    var b = Buffer(T){
        .memory = undefined,
        .fill = 0,
    };
    std.mem.set(u8, &b.memory, 0);
    return b;
}

// global state struct
const State = struct {
    rows: u32,
    cols: u32,
    offset: u32,
    highlight: u32,
    iptBuffer: Buffer(512),
    project: Buffer(64),
    context: Buffer(64),
    tasks: std.ArrayList(Task),
    filteredTasks: std.ArrayList(*Task),
    projectFilter: bool,
    contextFilter: bool,
};

// global state instance
var state = State{
    .rows = 0,
    .cols = 0,
    .offset = 0,
    .highlight = 0,
    .iptBuffer = buildBuffer(512),
    .project = buildBuffer(64),
    .context = buildBuffer(64),
    .tasks = undefined,
    .filteredTasks = undefined,
    .projectFilter = false,
    .contextFilter = false,
};

fn display() void {
    tui.clear();

    var j: u32 = 0;
    for (state.filteredTasks.items, 0..) |task, i| {
        if (i < state.offset) continue;
        tui.output(if (i == state.highlight) ">" else " ");

        if (task.done) {
            tui.setColour(tui.buildColour(tui.Colour.FG_WHITE, tui.ColourMod.LOW));
        }

        for (task.tokens.items) |token| {
            if (!task.done) {
                switch (token.type) {
                    TokType.DONE => {},
                    TokType.PRIORITY => {},
                    TokType.DATE => {
                        tui.setColour(tui.buildColour(tui.Colour.FG_YELLOW, tui.ColourMod.NONE));
                    },
                    TokType.WORDS => {
                        tui.setColour(tui.buildColour(tui.Colour.FG_DEFAULT, tui.ColourMod.NONE));
                    },
                    TokType.CONTEXT => {
                        tui.setColour(tui.buildColour(tui.Colour.FG_BLUE, tui.ColourMod.NONE));
                    },
                    TokType.PROJECT => {
                        tui.setColour(tui.buildColour(tui.Colour.FG_GREEN, tui.ColourMod.NONE));
                    },
                }
            }
            tui.output(token.data[0..std.math.min(state.cols - 2, token.data.len)]);
        }
        tui.output("\r\n");
        tui.setColour(tui.buildColour(tui.Colour.FG_DEFAULT, tui.ColourMod.NONE));

        j += 1;
        if (j == state.rows - 1) break;
    }

    for (0..(state.rows - j - 1)) |_| {
        tui.output("\r\n");
    }

    // print footer
    tui.outputFmt("({}/{})", .{ state.highlight + 1, state.filteredTasks.items.len }) catch {
        unreachable;
    };

    // print project filter status
    tui.setColour(if (state.projectFilter) tui.buildColour(tui.Colour.FG_GREEN, tui.ColourMod.BOLD) else tui.buildColour(tui.Colour.FG_WHITE, tui.ColourMod.LOW));
    tui.output(" | Project: ");
    if (state.projectFilter) tui.output(state.project.memory[0..state.project.fill]);

    // print context filter status
    tui.setColour(if (state.contextFilter) tui.buildColour(tui.Colour.FG_BLUE, tui.ColourMod.BOLD) else tui.buildColour(tui.Colour.FG_WHITE, tui.ColourMod.LOW));
    tui.output(" | Context: ");
    if (state.contextFilter) tui.output(state.context.memory[0..state.context.fill]);

    // reset for next run
    tui.setColour(tui.buildColour(tui.Colour.FG_WHITE, tui.ColourMod.NONE));
    tui.flush();
}

// read in a file
fn readInputFile(path: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const fileSize = stat.size;
    return try file.reader().readAllAlloc(alloc, fileSize);
}

// find index of elem in slice (like std.mem.indexOf)
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
        .hidden = false,
        .priority = 'Z',
        .creationDate = "",
        .completionDate = "",
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

    // look for a date - it's the creation date, unless ...
    if (slice[0] == '[') {
        if (find(u8, slice, ']')) |end| {
            if (end < slice.len and slice[end + 1] == ' ') {
                task.creationDate = slice[0..end];
                slice = slice[end + 2 ..];
            }
        }
    }

    // ... we find a second date, then its the completion data and
    // this is actually the creation data.
    if (slice[0] == '[') {
        if (find(u8, slice, ']')) |end| {
            if (end < slice.len and slice[end + 1] == ' ') {
                task.completionDate = task.creationDate;
                task.creationDate = slice[0..end];
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
            '+' => TokType.PROJECT,
            else => TokType.DONE,
        };

        if (token != TokType.DONE) {
            var end = find(u8, slice[idx..], ' ') orelse slice.len - idx;

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
    var shouldFilter = false;
    while (x != 'q') {
        display();
        x = tui.readKey() catch {
            unreachable; // TODO: smart stuff here
        };

        switch (x) {
            @enumToInt(tui.KeyName.KEY_UNKNOWN) => {}, // ignore unknown keys
            @enumToInt(tui.KeyName.KEY_ARROW_LEFT), 'h' => {
                state.filteredTasks.items[state.highlight].done = false;
            },
            @enumToInt(tui.KeyName.KEY_ARROW_RIGHT), 'l' => {
                state.filteredTasks.items[state.highlight].done = true;
            },
            @enumToInt(tui.KeyName.KEY_ARROW_UP), 'j' => {
                const m = state.offset;
                state.highlight = if (state.highlight == 0) state.highlight else state.highlight - 1;
                if (state.highlight < m) state.offset -= 1;
            },
            @enumToInt(tui.KeyName.KEY_ARROW_DOWN), 'k' => {
                const m = (state.rows + state.offset) - 2;
                state.highlight = if (state.highlight < state.filteredTasks.items.len - 1) state.highlight + 1 else state.highlight;
                if (state.highlight > m) state.offset += 1;
            },
            @enumToInt(tui.KeyName.KEY_DEL) => {},
            @enumToInt(tui.KeyName.KEY_HOME) => {},
            @enumToInt(tui.KeyName.KEY_END) => {},
            @enumToInt(tui.KeyName.KEY_PAGE_UP) => {},
            @enumToInt(tui.KeyName.KEY_PAGE_DOWN) => {},
            'p' => {
                buildFilter(@TypeOf(state.project), &state.project, state.filteredTasks.items[state.highlight], TokType.PROJECT);
                state.projectFilter = true;
                shouldFilter = true;
            },
            'P' => {
                state.projectFilter = false;
                shouldFilter = true;
            },
            'c' => {
                buildFilter(@TypeOf(state.context), &state.context, state.filteredTasks.items[state.highlight], TokType.CONTEXT);
                state.contextFilter = true;
                shouldFilter = true;
            },
            'C' => {
                state.contextFilter = false;
                shouldFilter = true;
            },
            else => {},
        }

        if (shouldFilter) {
            filterTasks() catch unreachable;
            shouldFilter = false;
        }
    }
}

fn filterTasks() !void {
    clearFilter();
    if (state.contextFilter) applyFilter(TokType.CONTEXT, &state.context.memory);
    if (state.projectFilter) applyFilter(TokType.PROJECT, &state.project.memory);
    try collectTasks();
    state.highlight = 0;
    state.offset = 0;
}

fn buildFilter(comptime T: type, buf: *T, task: *Task, tokType: TokType) void {
    buf.clear();
    for (task.tokens.items) |token| {
        if (token.type == tokType) {
            buf.pushBytes(token.data) catch {};
            buf.pushBytes(" ") catch {};
        }
    }
}

fn applyFilter(tokType: TokType, filterStr: []u8) void {
    filter: for (state.tasks.items) |*task| {
        if (task.hidden) continue :filter; // dont re-show hidden stuff

        task.hidden = true;
        var itr = std.mem.tokenize(u8, filterStr, " ");
        while (itr.next()) |entry| {
            for (task.tokens.items) |token| {
                if (token.type == tokType and std.mem.eql(u8, token.data, entry)) {
                    task.hidden = false;
                    continue :filter;
                }
            }
        }
    }
}

fn clearFilter() void {
    for (state.tasks.items) |*task| task.hidden = false;
}

fn collectTasks() !void {
    state.filteredTasks.clearRetainingCapacity();
    for (state.tasks.items) |*task| {
        if (!task.hidden) try state.filteredTasks.append(task);
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
    defer alloc.free(data);

    state.tasks = try parseLines(data, alloc);
    defer state.tasks.deinit();

    state.filteredTasks = std.ArrayList(*Task).init(alloc);
    defer state.filteredTasks.deinit();

    tui.enableRawMode();
    defer tui.disableRawMode();

    var ws = tui.getWinSz();
    state.cols = ws.ws_col;
    state.rows = ws.ws_row;

    try collectTasks();
    updateLoop();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
