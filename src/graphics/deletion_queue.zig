const std = @import("std");

//

pub const DeletionQueue = struct {
    queue: std.ArrayList(),
};

pub const Deletor = struct {};
