const peer = @import("../net/peer.zig");

pub fn share() void {
    peer.send();
}
