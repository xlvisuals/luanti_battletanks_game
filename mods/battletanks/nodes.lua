
minetest.register_node("battletanks:floor", {
    description = "BattleTanks Arena Floor",
    tiles = { battletanks.settings.tiles.arena_boundary_blue },
    groups = { battletanks_wall = 1, cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    light_source = 4,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:boundary", {
    description = "BattleTanks Arena Boundary (blue)",
    tiles = { battletanks.settings.tiles.arena_boundary_blue },
    groups = { battletanks_wall = 1, cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    light_source = 4,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:boundary_silver", {
    description = "BattleTanks Arena Boundary (silver)",
    tiles = { battletanks.settings.tiles.arena_boundary_silver },
    groups = { battletanks_wall = 1, cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    light_source = 4,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:boundary_blue", {
    description = "BattleTanks Arena Boundary (Blue)",
    tiles = { battletanks.settings.tiles.arena_boundary_blue },
    groups = { battletanks_wall = 1, cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    light_source = 4,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

for n = 1, 8 do
    minetest.register_node("battletanks:spawnpad_" .. n, {
        description = "BattleTanks Spawn Point " .. n .. " (place facing the direction that racer should start moving)",
        tiles = { "battletanks_spawnpad_" .. n .. ".png" },
        paramtype2 = "facedir",
        groups = { cracky = 3, not_in_creative_inventory = 1 },
        is_ground_content = false,
        light_source = 4,
        walkable = true,
        can_dig = function(pos, digger)
            if not digger then return false end
            return battletanks.is_build_mode_on(digger:get_player_name())
        end,
        after_place_node = function(pos, placer)
            if placer and placer:is_player() then
                local param2 = minetest.dir_to_facedir(placer:get_look_dir())
                minetest.swap_node(pos, { name = "battletanks:spawnpad_" .. n, param2 = param2 })
            end
        end,
    })
end


minetest.register_node("battletanks:powerup_point_spawner", {
    description = "BattleTanks Point Powerup Spawner (level-designer placed, admin/build-mode only to dig)",
    tiles = { "battletanks_powerup_point.png" },
    walkable = false,
    light_source = 6, -- dimmer than the actual in-match collectible, so the two read differently
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:powerup_point", {
    description = "BattleTanks Point Powerup (spawned automatically at match start, never placed by hand)",
    tiles = { "battletanks_powerup_point.png" },
    walkable = false,
    light_source = 12,
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:powerup_boost", {
    description = "BattleTanks Boost Powerup (spawned automatically, never placed by hand)",
    tiles = { "battletanks_powerup_boost.png" },
    walkable = false,
    light_source = 12,
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:powerup_shield", {
    description = "BattleTanks Shield Powerup (spawned automatically, never placed by hand)",
    tiles = { "battletanks_powerup_shield.png" },
    walkable = false,
    light_source = 12,
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:powerup_laser", {
    description = "BattleTanks Laser Powerup (spawned automatically, never placed by hand)",
    tiles = { "battletanks_powerup_laser.png" },
    walkable = false,
    light_source = 12,
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})

minetest.register_node("battletanks:powerup_rocket", {
    description = "BattleTanks Rocket Powerup (spawned automatically, never placed by hand)",
    tiles = { "battletanks_powerup_rocket.png" },
    walkable = false,
    light_source = 12,
    groups = { cracky = 3, not_in_creative_inventory = 1 },
    is_ground_content = false,
    can_dig = function(pos, digger)
        if not digger then return false end
        return battletanks.is_build_mode_on(digger:get_player_name())
    end,
})
