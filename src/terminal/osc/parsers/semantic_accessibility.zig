const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse the private OSC 6973 semantic accessibility payload.
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"6973");

    const cap = if (parser.capture) |*capture| capture else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    if (data.len <= 1) {
        parser.state = .invalid;
        return null;
    }

    parser.command = .{
        .semantic_accessibility = data[0 .. data.len - 1 :0],
    };
    return &parser.command;
}

test "OSC: 6973 semantic accessibility payload" {
    const testing = std.testing;

    var parser: Parser = .init(testing.allocator);
    defer parser.deinit();

    for ("6973;eyJ2ZXJzaW9uIjoxfQ==") |ch| parser.next(ch);
    const command = parser.end('\x1b') orelse return error.TestExpectedEqual;
    try testing.expect(command.* == .semantic_accessibility);
    try testing.expectEqualStrings("eyJ2ZXJzaW9uIjoxfQ==", command.semantic_accessibility);
}
