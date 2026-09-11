
minetest.register_tool("battletanks:build_pick", {
    description = "BattleTanks Build Tool (fast-digs everything, admin/build-mode only)",
    inventory_image = "battletanks_build_pick.png",
    range = battletanks.settings.build_tool_range, -- how far it reaches for digging/placing, in nodes
    tool_capabilities = {
        full_punch_interval = 0.3,
        max_drop_level = 3,
        groupcaps = {
            cracky = { times = { [1] = 0.2, [2] = 0.2, [3] = 0.2 }, uses = 0, maxlevel = 3 },
            crumbly = { times = { [1] = 0.2, [2] = 0.2, [3] = 0.2 }, uses = 0, maxlevel = 3 },
            snappy = { times = { [1] = 0.2, [2] = 0.2, [3] = 0.2 }, uses = 0, maxlevel = 3 },
            choppy = { times = { [1] = 0.2, [2] = 0.2, [3] = 0.2 }, uses = 0, maxlevel = 3 },
            oddly_breakable_by_hand = { times = { [1] = 0.2, [2] = 0.2, [3] = 0.2 }, uses = 0, maxlevel = 3 },
        },
        damage_groups = { fleshy = 1 },
    },
    groups = { not_in_creative_inventory = 1 },
})

battletanks.settings.build_mode_items = {
    "battletanks:build_pick 1",
    "battletanks:boundary 99",
    "battletanks:powerup_point_spawner 99",
    "battletanks:spawnpad_1 1",
    "battletanks:spawnpad_2 1",
    "battletanks:spawnpad_3 1",
    "battletanks:spawnpad_4 1",
    "battletanks:spawnpad_5 1",
    "battletanks:spawnpad_6 1",
    "battletanks:spawnpad_7 1",
    "battletanks:spawnpad_8 1",
}

local function build_privs()
    local privs = { give = true, fly = true, fast = true, noclip = true, teleport = true }
    if minetest.registered_privileges["worldedit"] then
        privs.worldedit = true
    end
    return privs
end

function battletanks.is_build_mode_on(name)
    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(build_privs()) do
        if not privs[priv] then return false end
    end
    return true
end

function battletanks.set_build_mode(name, on)
    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(build_privs()) do
        privs[priv] = on or nil
    end
    minetest.set_player_privs(name, privs)

    local player = minetest.get_player_by_name(name)
    if not player then return end

    local inv = player:get_inventory()
    if on then
        for _, itemstring in ipairs(battletanks.settings.build_mode_items) do
            inv:add_item("main", ItemStack(itemstring))
        end
    else
        inv:set_list("main", {})
    end

    local flags = player:hud_get_flags()
    flags.wielditem = on
    flags.crosshair = on
    player:hud_set_flags(flags)

    if not battletanks.players[name] then
        if on then
            player:set_physics_override({
                speed = 1, jump = 1, gravity = 0, sneak = true, sneak_glitch = false,
            })
        else
            lobby_system.enter_idle_state(player)
        end
    end
end

lobby_system.set_before_show_fn(function(name)
    if battletanks.is_build_mode_on(name) then
        battletanks.set_build_mode(name, false)
        minetest.chat_send_player(name, "[BattleTanks] Build mode OFF - privileges revoked.")
    end
end)

minetest.register_chatcommand("btspawns", {
    params = "[<1-8>]",
    description = "BattleTanks map-building helper: list all spawn point "
        .. "coordinates, or teleport to one, for precisely aligning obstacles "
        .. "and WorldEdit selections. Needs the lobby_admin priv.",
    func = function(name, param)
        if not minetest.check_player_privs(name, { lobby_admin = true }) then
            return false, "Needs the lobby_admin priv."
        end

        local points = battletanks.spawn_points()
        param = (param or ""):match("^%s*(.-)%s*$")

        if param == "" then
            local lines = { "BattleTanks spawn points:" }
            for i = 1, #points, 2 do
                local a = points[i]
                local b = points[i + 1]
                local line = string.format("  %d: (%d, %d, %d) yaw=%.2f",
                    i, a.pos.x, a.pos.y, a.pos.z, a.yaw)
                if b then
                    line = line .. string.format("   %d: (%d, %d, %d) yaw=%.2f",
                        i + 1, b.pos.x, b.pos.y, b.pos.z, b.yaw)
                end
                table.insert(lines, line)
            end
            table.insert(lines, "Use /btspawns <1-8> to teleport to one.")
            return true, table.concat(lines, "\n")
        end

        local i = tonumber(param)
        if not i or not points[i] then
            return false, "Give a spawn number 1-8, or no argument to list them all."
        end

        local player = minetest.get_player_by_name(name)
        if player then
            player:set_pos(points[i].pos)
            player:set_look_horizontal(points[i].yaw)
            player:set_look_vertical(0)
        end
        return true, string.format("Teleported to spawn %d: (%d, %d, %d).",
            i, points[i].pos.x, points[i].pos.y, points[i].pos.z)
    end,
})
