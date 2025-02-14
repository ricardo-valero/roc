const std = @import("std");
const base = @import("../../base.zig");
const problem_mod = @import("../../problem.zig");
const collections = @import("../../collections.zig");

const Alias = @import("./Alias.zig");

const Ident = base.Ident;
const Region = base.Region;
const Module = base.Module;
const TagName = base.TagName;
const Problem = problem_mod.Problem;
const exitOnOom = collections.utils.exitOnOom;

const Self = @This();

env: *base.ModuleEnv,
/// The custom alias that this file is centered around, if one has been defined.
focused_custom_alias: ?Alias.Idx,
// TODO: handle renaming, e.g. `CustomType := [ExportedName as LocalName]`
custom_tags: std.AutoHashMap(TagName.Idx, Alias.Idx),
/// Identifiers/aliases that are in scope, and defined in the current module.
levels: Levels,
allocator: std.mem.Allocator,

pub fn init(
    env: *base.ModuleEnv,
    builtin_aliases: []const struct { alias: Alias.Idx, name: TagName.Idx },
    builtin_idents: []const Ident.Idx,
    allocator: std.mem.Allocator,
) Self {
    var scope = Self{
        .env = env,
        .focused_custom_alias = null,
        .custom_tags = std.AutoHashMap(TagName.Idx, Alias.Idx).init(allocator),
        .levels = Levels.init(env, allocator),
        .allocator = allocator,
    };

    scope.levels.enter();

    for (builtin_idents) |builtin_ident| {
        _ = scope.levels.introduce(.ident, .{
            .scope_name = builtin_ident,
            .ident = builtin_ident,
        });
    }

    for (builtin_aliases) |builtin_alias| {
        _ = scope.levels.introduce(.alias, .{
            .scope_name = builtin_alias.name,
            .alias = builtin_alias.alias,
        });
    }

    return scope;
}

pub fn deinit(self: *Self) void {
    self.custom_tags.deinit();
    self.levels.deinit();
}

/// Generates a unique ident like "1" or "5" in the home module.
///
/// This is used, for example, during canonicalization of an Expr::Closure
/// to generate a unique ident to refer to that closure.
pub fn genUnique(self: *Self) Ident.Idx {
    const unique_idx = self.env.idents.genUnique();

    _ = self.levels.introduce(.ident, .{
        .scope_name = unique_idx,
        .ident = unique_idx,
    });

    return unique_idx;
}

pub fn Contains(item_kind: Level.ItemKind) type {
    return union(enum) {
        InScope: Level.Name(item_kind),
        NotInScope: Level.Name(item_kind),
        NotPresent,
    };
}

pub fn LookupResult(item_kind: Level.ItemKind) type {
    return union(enum) {
        InScope: Level.Name(item_kind),
        Problem: Problem,
    };
}

pub const Level = struct {
    idents: std.ArrayList(IdentInScope),
    aliases: std.ArrayList(AliasInScope),

    pub const ItemKind = enum { ident, alias };

    pub fn Item(comptime item_kind: ItemKind) type {
        return switch (item_kind) {
            .ident => IdentInScope,
            .alias => AliasInScope,
        };
    }

    pub fn ItemName(comptime item_kind: ItemKind) type {
        return switch (item_kind) {
            .ident => Ident.Idx,
            .alias => TagName.Idx,
        };
    }

    pub fn items(level: *Level, comptime item_kind: ItemKind) *std.ArrayList(Item(item_kind)) {
        return switch (item_kind) {
            .ident => &level.idents,
            .alias => &level.aliases,
        };
    }

    pub const IdentInScope = struct {
        scope_name: Ident.Idx,
        ident: Ident.Idx,
    };

    pub const AliasInScope = struct {
        scope_name: TagName.Idx,
        alias: Alias.Idx,
    };

    pub fn init(allocator: std.mem.Allocator) Level {
        return Level{
            .idents = std.ArrayList(IdentInScope).init(allocator),
            .aliases = std.ArrayList(AliasInScope).init(allocator),
        };
    }

    pub fn deinit(self: *Level) void {
        self.idents.deinit();
        self.aliases.deinit();
    }
};

pub const Levels = struct {
    env: *base.ModuleEnv,
    levels: std.ArrayList(Level),
    allocator: std.mem.Allocator,

    pub fn init(env: *base.ModuleEnv, allocator: std.mem.Allocator) Levels {
        return Levels{
            .env = env,
            .levels = std.ArrayList(Level).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Levels) void {
        self.levels.deinit();
    }

    pub fn enter(self: *Levels) void {
        self.levels.append(Level.init(self.allocator)) catch exitOnOom();
    }

    pub fn exit(self: *Levels) void {
        if (self.levels.items.len <= 1) {
            self.env.problems.append(Problem.Compiler.Canonicalize.make(.ExitedTopScopeLevel)) catch exitOnOom();
        } else {
            _ = self.levels.pop();
        }
    }

    pub fn iter(self: *Levels, comptime item_kind: Level.ItemKind) Iterator(item_kind) {
        return Iterator(item_kind).new(self);
    }

    fn contains(
        self: *Levels,
        comptime item_kind: Level.ItemKind,
        name: Level.ItemName(item_kind),
    ) ?Level.Item(item_kind) {
        var items_in_scope = Iterator(item_kind).new(self);
        while (items_in_scope.nextData()) |item_in_scope| {
            switch (item_kind) {
                .ident => {
                    if (self.env.idents.identsHaveSameText(name, item_in_scope.scope_name)) {
                        return item_in_scope;
                    }
                },
                .alias => {
                    if (self.env.tag_names.namesHaveSameText(name, item_in_scope.scope_name)) {
                        return item_in_scope;
                    }
                },
            }
        }

        return null;
    }

    pub fn lookup(
        self: *Levels,
        comptime item_kind: Level.ItemKind,
        name: Level.ItemName(item_kind),
    ) Contains(item_kind) {
        if (self.contains(name)) |item_in_scope| {
            return Contains{ .InScope = item_in_scope };
        }

        const problem = undefined;
        switch (item_kind) {
            .ident => {
                const all_idents_in_scope = self.levels.iter(.ident);
                const options = self.env.ident_ids_for_slicing.extendFromIter(all_idents_in_scope);

                problem = Problem.Canonicalize.make(.{ .IdentNotInScope = .{
                    .ident = name,
                    .suggestions = options,
                } });
            },
            .alias => {
                const all_aliases_in_scope = self.levels.iter(.alias);
                const options = self.env.tag_name_ids_for_slicing.extendFromIter(all_aliases_in_scope);

                problem = Problem.Canonicalize.make(.{ .AliasNotInScope = .{
                    .name = name,
                    .suggestions = options,
                } });
            },
        }

        self.env.problems.append(problem) catch exitOnOom();
        return LookupResult{ .Problem = problem };
    }

    pub fn introduce(
        self: *Levels,
        comptime item_kind: Level.ItemKind,
        scope_item: Level.Item(item_kind),
    ) Level.Item(item_kind) {
        if (self.contains(item_kind, scope_item.scope_name)) |item_in_scope| {
            const can_problem = switch (item_kind) {
                .ident => .{ .IdentAlreadyInScope = .{
                    .original_ident = item_in_scope.scope_name,
                    .shadow = scope_item.scope_name,
                } },
                .alias => .{ .AliasAlreadyInScope = .{
                    .original_name = item_in_scope.scope_name,
                    .shadow = scope_item.scope_name,
                } },
            };

            self.env.problems.append(Problem.Canonicalize.make(can_problem)) catch exitOnOom();
            // TODO: is this correct for shadows?
            return scope_item;
        }

        var last_level = self.levels.getLast();
        last_level.items(item_kind).append(scope_item) catch exitOnOom();

        return scope_item;
    }

    pub fn Iterator(comptime item_kind: Level.ItemKind) type {
        return struct {
            levels: *Levels,
            level_index: usize,
            prior_item_index: usize,

            pub fn empty(levels: *Levels) Iterator(item_kind) {
                return Iterator(item_kind){
                    .levels = levels,
                    .level_index = 0,
                    .prior_item_index = 0,
                };
            }

            pub fn new(scope_levels: *Levels) Iterator(item_kind) {
                if (scope_levels.levels.items.len == 0) {
                    return empty(scope_levels);
                }

                const levels = scope_levels.levels.items;

                var level_index = levels.len -| 1;
                while (level_index > 0 and levels[level_index].items(item_kind).items.len == 0) {
                    level_index -= 1;
                }

                const prior_item_index = levels[level_index].items(item_kind).items.len;

                return Iterator(item_kind){
                    .levels = scope_levels,
                    .level_index = level_index,
                    .prior_item_index = prior_item_index,
                };
            }

            pub fn next(
                self: *Iterator(item_kind),
            ) ?Level.ItemName(item_kind) {
                if (self.prior_item_index == 0) {
                    return null;
                }

                const levels = self.levels.levels.items.items;
                var level = levels[self.level_index];
                const next_item = level.items(item_kind)[self.prior_item_index - 1];

                self.prior_item_index -= 1;

                if (self.prior_item_index == 0) {
                    self.level_index -|= 1;

                    while (self.level_index > 0 and levels[self.level_index].items(item_kind).len == 0) {
                        self.level_index -= 1;
                    }
                }

                return next_item.scope_name;
            }

            pub fn nextData(
                self: *Iterator(item_kind),
            ) ?Level.Item(item_kind) {
                if (self.prior_item_index == 0) {
                    return null;
                }

                const levels = self.levels.levels.items;
                var level = levels[self.level_index];
                const next_item = level.items(item_kind).items[self.prior_item_index - 1];

                self.prior_item_index -= 1;

                if (self.prior_item_index == 0) {
                    self.level_index -|= 1;

                    while (self.level_index > 0 and levels[self.level_index].items(item_kind).items.len == 0) {
                        self.level_index -= 1;
                    }
                }

                return next_item;
            }
        };
    }
};
