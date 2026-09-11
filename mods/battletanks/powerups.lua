
local S = battletanks.settings

battletanks.powerup_spawn_generation = 0


local active_point_powerups = {}
local had_point_powerups_this_match = false

function battletanks.despawn_point_powerup_entities()
    for _, pos in ipairs(active_point_powerups) do
        if minetest.get_node(pos).name == "battletanks:powerup_point" then
            minetest.set_node(pos, { name = "air" })
        end
    end
    active_point_powerups = {}
end

function battletanks.spawn_point_powerup_entities()
    battletanks.despawn_point_powerup_entities()
    had_point_powerups_this_match = false

    local b = battletanks.arena_bounds()
    local collectible_y = b.y0 + 1
    for x = b.min_x, b.max_x do
        for z = b.min_z, b.max_z do
            for y = b.y0, b.y0 + S.wall_height do
                local pos = { x = x, y = y, z = z }
                if minetest.get_node(pos).name == "battletanks:powerup_point_spawner" then
                    local collectible_pos = { x = x, y = collectible_y, z = z }
                    minetest.set_node(collectible_pos, { name = "battletanks:powerup_point" })
                    table.insert(active_point_powerups, collectible_pos)
                    had_point_powerups_this_match = true
                    break -- found this column's spawner (if any); don't also match a second one stacked above it
                end
            end
        end
    end

    if had_point_powerups_this_match then
        battletanks.powerup_spawn_generation = battletanks.powerup_spawn_generation + 1
    end
end


local function random_open_position()
    local b = battletanks.arena_bounds()
    local y = b.y0 + 1
    for _ = 1, 20 do
        local x = math.random(b.min_x + 1, b.max_x - 1)
        local z = math.random(b.min_z + 1, b.max_z - 1)
        local pos = { x = x, y = y, z = z }
        if minetest.get_node(pos).name == "air" and not battletanks.is_pit(x, z) then
            return pos
        end
    end
    return nil -- arena too full of trails to find a spot this attempt; skip this tank
end

-- Handles a powerup type that spawns at random open spots on a timer
-- (boost/shield/laser/rocket - point powerups are placed as part of the
-- level itself via spawner nodes, not through here). Up to `max_key`
-- instances of this type can be unclaimed on the arena at once; once
-- that many are already out, a spawn event is simply skipped (not queued
-- or delayed to "catch up" later) rather than exceeding the cap.
local function make_random_powerup(node_name, enabled_key, interval_key, lifetime_key, max_key)
    local active = {} -- list of { pos = {x=,y=,z=}, expiry_job = <job> }
    local spawn_loop_job = nil -- job handle for the currently-scheduled next spawn attempt

    local function remove_instance(index)
        local inst = active[index]
        if not inst then return end
        if inst.expiry_job then inst.expiry_job:cancel() end
        if minetest.get_node(inst.pos).name == node_name then
            minetest.set_node(inst.pos, { name = "air" })
        end
        table.remove(active, index)
    end

    -- Removes whichever instance is sitting at `pos` - used when a racer
    -- actually picks one up, so only that one instance disappears rather
    -- than every other still-unclaimed one of the same type.
    local function remove_at(pos)
        for i, inst in ipairs(active) do
            if vector.equals(inst.pos, pos) then
                remove_instance(i)
                return
            end
        end
    end

    -- Removes every currently-unclaimed instance of this type - match end,
    -- or an admin turning this powerup type off mid-match.
    local function clear_all()
        for i = #active, 1, -1 do
            remove_instance(i)
        end
    end

    local function spawn(generation)
        if battletanks.match_generation ~= generation then return end
        if not S[enabled_key] or lobby_system.state.phase ~= "playing" then return end
        if #active >= S[max_key] then return end -- already at the cap for this type - skip this spawn event
        local pos = random_open_position()
        if pos then
            minetest.set_node(pos, { name = node_name })
            local inst = { pos = pos }
            table.insert(active, inst)
            battletanks.powerup_spawn_generation = battletanks.powerup_spawn_generation + 1
            inst.expiry_job = minetest.after(S[lifetime_key], function()
                if battletanks.match_generation == generation and lobby_system.state.phase == "playing" then
                    remove_at(inst.pos)
                end
            end)
        end
    end

    local function start_loop(generation)
        active = {}
        if spawn_loop_job then spawn_loop_job:cancel(); spawn_loop_job = nil end -- defensive, shouldn't normally still be one
        local function tick()
            if battletanks.match_generation ~= generation then return end
            if lobby_system.state.phase ~= "playing" then return end
            spawn(generation)
            spawn_loop_job = minetest.after(S[interval_key], tick)
        end
        spawn_loop_job = minetest.after(S[interval_key], tick)
    end

    local function stop_loop()
        if spawn_loop_job then spawn_loop_job:cancel(); spawn_loop_job = nil end
        clear_all()
    end

    local function get_active_positions()
        local copy = {}
        for _, inst in ipairs(active) do
            table.insert(copy, { x = inst.pos.x, y = inst.pos.y, z = inst.pos.z })
        end
        return copy
    end

    return {
        clear_active = clear_all, remove_at = remove_at,
        start_loop = start_loop, stop_loop = stop_loop,
        get_active_positions = get_active_positions,
    }
end

local boost_powerup = make_random_powerup("battletanks:powerup_boost",
    "boost_powerups_enabled", "boost_powerup_interval", "boost_powerup_lifetime", "boost_powerup_max")
local shield_powerup = make_random_powerup("battletanks:powerup_shield",
    "shield_powerups_enabled", "shield_powerup_interval", "shield_powerup_lifetime", "shield_powerup_max")
local laser_powerup = make_random_powerup("battletanks:powerup_laser",
    "laser_powerups_enabled", "laser_powerup_interval", "laser_powerup_lifetime", "laser_powerup_max")
local rocket_powerup = make_random_powerup("battletanks:powerup_rocket",
    "rocket_powerups_enabled", "rocket_powerup_interval", "rocket_powerup_lifetime", "rocket_powerup_max")

function battletanks.clear_active_boost_powerup() boost_powerup.clear_active() end
function battletanks.start_boost_powerup_loop(generation) boost_powerup.start_loop(generation) end
function battletanks.stop_boost_powerup_loop() boost_powerup.stop_loop() end

function battletanks.clear_active_laser_powerup() laser_powerup.clear_active() end
function battletanks.start_laser_powerup_loop(generation) laser_powerup.start_loop(generation) end
function battletanks.stop_laser_powerup_loop() laser_powerup.stop_loop() end

function battletanks.clear_active_rocket_powerup() rocket_powerup.clear_active() end
function battletanks.start_rocket_powerup_loop(generation) rocket_powerup.start_loop(generation) end
function battletanks.stop_rocket_powerup_loop() rocket_powerup.stop_loop() end


function battletanks.get_active_point_powerup_positions()
    local copy = {}
    for _, pos in ipairs(active_point_powerups) do
        table.insert(copy, { x = pos.x, y = pos.y, z = pos.z })
    end
    return copy
end

function battletanks.get_active_boost_powerup_positions()
    return boost_powerup.get_active_positions()
end

function battletanks.get_active_shield_powerup_positions()
    return shield_powerup.get_active_positions()
end

function battletanks.get_active_laser_powerup_positions()
    return laser_powerup.get_active_positions()
end

function battletanks.get_active_rocket_powerup_positions()
    return rocket_powerup.get_active_positions()
end

function battletanks.clear_active_shield_powerup() shield_powerup.clear_active() end
function battletanks.start_shield_powerup_loop(generation) shield_powerup.start_loop(generation) end
function battletanks.stop_shield_powerup_loop() shield_powerup.stop_loop() end


function battletanks.check_powerup_pickup(name, pdata, pos)
    local rounded = vector.round(pos)
    rounded.y = battletanks.arena_bounds().y0 + 1
    local node = minetest.get_node(rounded)

    if S.point_powerups_enabled and node.name == "battletanks:powerup_point" then
        minetest.set_node(rounded, { name = "air" })
        for i, p in ipairs(active_point_powerups) do
            if vector.equals(p, rounded) then
                table.remove(active_point_powerups, i)
                break
            end
        end

        lobby_system.add_score(name, S.point_powerup_value)
        pdata.battle_score = pdata.battle_score + S.point_powerup_value
        lobby_system.hud.update_all_scoreboards()
        battletanks.hud.update_battle_table()
        battletanks.sounds.play_point_pickup(rounded)
        minetest.chat_send_all("[BattleTanks] " .. name .. " picked up +" .. S.point_powerup_value .. " points!")

        local racer_count = 0
        for _ in pairs(battletanks.players) do racer_count = racer_count + 1 end
        if racer_count == 1 and had_point_powerups_this_match and #active_point_powerups == 0 then
            battletanks.end_match(name)
        end
    end

    if S.boost_powerups_enabled and node.name == "battletanks:powerup_boost" then
        minetest.set_node(rounded, { name = "air" })
        boost_powerup.remove_at(rounded)
        pdata.boost = 100
        battletanks.sounds.play_boost_pickup(rounded)
        minetest.chat_send_all("[BattleTanks] " .. name .. " picked up a boost powerup!")
    end

    if S.shield_powerups_enabled and node.name == "battletanks:powerup_shield" then
        minetest.set_node(rounded, { name = "air" })
        shield_powerup.remove_at(rounded)
        pdata.shield = (pdata.shield or 0) + 1
        battletanks.hud.update_shield(minetest.get_player_by_name(name), pdata.shield)
        battletanks.sounds.play_shield_pickup(rounded)
        minetest.chat_send_all("[BattleTanks] " .. name .. " picked up a shield (" .. pdata.shield .. " now).")
    end

    if S.laser_powerups_enabled and node.name == "battletanks:powerup_laser" then
        minetest.set_node(rounded, { name = "air" })
        laser_powerup.remove_at(rounded)
        pdata.laser = (pdata.laser or 0) + S.laser_per_pickup
        battletanks.hud.update_laser(minetest.get_player_by_name(name), pdata.laser)
        battletanks.sounds.play_laser_pickup(rounded)
        minetest.chat_send_all("[BattleTanks] " .. name .. " picked up laser (" .. pdata.laser .. " now).")
    end

    if S.rocket_powerups_enabled and node.name == "battletanks:powerup_rocket" then
        minetest.set_node(rounded, { name = "air" })
        rocket_powerup.remove_at(rounded)
        pdata.rocket = (pdata.rocket or 0) + S.rocket_per_pickup
        battletanks.hud.update_rocket(minetest.get_player_by_name(name), pdata.rocket)
        battletanks.sounds.play_rocket_pickup(rounded)
        minetest.chat_send_all("[BattleTanks] " .. name .. " picked up rocket (" .. pdata.rocket .. " now).")
    end
end
