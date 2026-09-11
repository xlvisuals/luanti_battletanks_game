
battletanks.bots = {}

local S = battletanks.settings

local ALL_BEHAVIORS = { "passive", "opportunistic", "aggressive" }

lobby_system.set_extra_known_names_fn(function()
    local names = {}
    for name, pdata in pairs(battletanks.players) do
        if pdata.is_bot then table.insert(names, name) end
    end
    return names
end)

local random_behavior_assignments = {} -- slot number -> behavior string

lobby_system.set_on_new_game_fn(function()
    random_behavior_assignments = {}
end)

function battletanks.bots.resolve_behavior(slot_number)
    if S.bot_behavior ~= "random" then
        return S.bot_behavior
    end
    if not random_behavior_assignments[slot_number] then
        random_behavior_assignments[slot_number] = ALL_BEHAVIORS[math.random(#ALL_BEHAVIORS)]
    end
    return random_behavior_assignments[slot_number]
end

function battletanks.bots.behavior_letter(behavior)
    return behavior:sub(1, 1)
end

local LOOKAHEAD = 3

local OPPORTUNISTIC_RANGE = 10

local function is_hazard_node(node_name)
    local node_def = minetest.registered_nodes[node_name]
    return minetest.get_item_group(node_name, "battletanks_wall") == 1
        or (node_def and node_def.walkable)
end

local function is_hazard_or_pit_at(pos)
    return is_hazard_node(minetest.get_node(pos).name) or battletanks.is_pit(pos.x, pos.z)
end

local function path_clear(pos, dir, dist)
    for step = 1, dist do
        local check = vector.round(vector.add(pos, vector.multiply(dir, step)))
        check.y = S.arena_center.y + 1
        if is_hazard_or_pit_at(check) then
            return false
        end
    end
    return true
end

local MAX_OPENNESS_SEARCH = 20

local function measure_openness(pos, dir)
    for step = 1, MAX_OPENNESS_SEARCH do
        local check = vector.round(vector.add(pos, vector.multiply(dir, step)))
        check.y = S.arena_center.y + 1
        if is_hazard_or_pit_at(check) then
            return step - 1
        end
    end
    return MAX_OPENNESS_SEARCH
end

local function decide_passive(pos, dir)
    if path_clear(pos, dir, LOOKAHEAD) then
        return {} -- nothing blocking - keep going straight
    end

    local left_dir = { x = -dir.z, y = 0, z = dir.x }
    local right_dir = { x = dir.z, y = 0, z = -dir.x }

    local left_clear = path_clear(pos, left_dir, LOOKAHEAD)
    local right_clear = path_clear(pos, right_dir, LOOKAHEAD)

    local turn_left
    if left_clear and not right_clear then
        turn_left = true
    elseif right_clear and not left_clear then
        turn_left = false
    elseif left_clear and right_clear then
        local left_open = measure_openness(pos, left_dir)
        local right_open = measure_openness(pos, right_dir)
        if left_open == right_open then
            turn_left = math.random() < 0.5
        else
            turn_left = left_open > right_open
        end
    else
        turn_left = math.random() < 0.5 -- both blocked - trapped either way, pick one
    end

    return turn_left and { left = true } or { right = true }
end

local function find_nearest_powerup(pos, range)
    local best_pos, best_dist_sq = nil, range and (range * range) or math.huge

    local function consider(p)
        if not p then return end
        local dx, dz = p.x - pos.x, p.z - pos.z
        local d = dx * dx + dz * dz
        if d <= best_dist_sq then
            best_pos, best_dist_sq = p, d
        end
    end

    for _, p in ipairs(battletanks.get_active_point_powerup_positions()) do
        consider(p)
    end
    for _, p in ipairs(battletanks.get_active_boost_powerup_positions()) do
        consider(p)
    end
    for _, p in ipairs(battletanks.get_active_shield_powerup_positions()) do
        consider(p)
    end
    for _, p in ipairs(battletanks.get_active_laser_powerup_positions()) do
        consider(p)
    end
    for _, p in ipairs(battletanks.get_active_rocket_powerup_positions()) do
        consider(p)
    end

    return best_pos
end

local function powerup_still_at(target)
    local check = vector.round(target)
    check.y = S.arena_center.y + 1
    local n = minetest.get_node(check).name
    return n == "battletanks:powerup_point" or n == "battletanks:powerup_boost"
        or n == "battletanks:powerup_shield" or n == "battletanks:powerup_laser"
        or n == "battletanks:powerup_rocket"
end

local function steer_towards(pos, dir, target)
    local dx = target.x - pos.x
    local dz = target.z - pos.z
    if math.abs(dx) < 0.5 and math.abs(dz) < 0.5 then
        return {}, true -- close enough that pickup detection will catch it
    end

    local left_dir = { x = -dir.z, y = 0, z = dir.x }
    local right_dir = { x = dir.z, y = 0, z = -dir.x }

    local straight_helps = (dir.x * dx + dir.z * dz) > 0
    if straight_helps and path_clear(pos, dir, LOOKAHEAD) then
        return {}, true
    end

    local left_helps = (left_dir.x * dx + left_dir.z * dz) > 0
    local right_helps = (right_dir.x * dx + right_dir.z * dz) > 0

    if left_helps and path_clear(pos, left_dir, LOOKAHEAD) then
        return { left = true }, true
    end
    if right_helps and path_clear(pos, right_dir, LOOKAHEAD) then
        return { right = true }, true
    end

    return nil, false
end

local function decide_opportunistic(pdata, pos, dir)
    if pdata.bot_target and not powerup_still_at(pdata.bot_target) then
        pdata.bot_target = nil -- collected/expired before we got there
    end

    if not pdata.bot_target then
        pdata.bot_target = find_nearest_powerup(pos, OPPORTUNISTIC_RANGE)
    end

    if pdata.bot_target then
        local controls, still_useful = steer_towards(pos, dir, pdata.bot_target)
        if still_useful then
            return controls
        end
        pdata.bot_target = nil -- path blocked - give up on this one, same as "obstacle encountered"
    end

    return decide_passive(pos, dir)
end

-- The "dumb version" hunt behavior called for in the conversion notes:
-- drive toward the nearest other alive tank's current position, no real
-- pathfinding - if steer_towards can't make progress this tick (path
-- blocked), fall through to powerup-seeking/wandering below instead of
-- getting stuck. Recomputed fresh every tick (unlike powerup targets,
-- which are cached until collected/expired) since enemy tanks are always
-- moving.
local function find_nearest_enemy_pos(self_pdata, pos)
    local best_pos, best_dist_sq = nil, math.huge
    for _, other_pdata in pairs(battletanks.players) do
        if other_pdata ~= self_pdata and other_pdata.alive and other_pdata.tank_obj then
            local other_pos = other_pdata.tank_obj:get_pos()
            if other_pos then
                local dx, dz = other_pos.x - pos.x, other_pos.z - pos.z
                local d = dx * dx + dz * dz
                if d < best_dist_sq then
                    best_pos, best_dist_sq = { x = other_pos.x, y = pos.y, z = other_pos.z }, d
                end
            end
        end
    end
    return best_pos
end

-- Tanks aren't melee weapons: an aggressive bot stops closing in once it's
-- within this many nodes of its target, instead of shoving its barrel into
-- the enemy's rear bumper. It'll still turn to line up a shot at that
-- range - see decide_aggressive - just without driving any closer.
local ENGAGEMENT_RANGE = 3

local function decide_aggressive(pdata, pos, dir)
    local enemy_pos = find_nearest_enemy_pos(pdata, pos)
    if enemy_pos then
        local dx, dz = enemy_pos.x - pos.x, enemy_pos.z - pos.z
        if (dx * dx + dz * dz) <= ENGAGEMENT_RANGE * ENGAGEMENT_RANGE then
            -- Close enough - hold this distance. Still turn to line up a
            -- shot if steer_towards thinks that'd help, but never move
            -- forward toward the target from here.
            local controls = steer_towards(pos, dir, enemy_pos)
            controls.up = false
            return controls
        end

        local controls, still_useful = steer_towards(pos, dir, enemy_pos)
        if still_useful then
            return controls
        end
        -- Blocked this tick - fall through to powerup-seeking/wandering
        -- below rather than trying to shove through a wall.
    end

    if pdata.bot_target and not powerup_still_at(pdata.bot_target) then
        pdata.bot_target = nil -- reached/collected/expired
    end

    local generation = battletanks.powerup_spawn_generation
    if not pdata.bot_target or pdata.bot_target_generation ~= generation then
        pdata.bot_target = find_nearest_powerup(pos, nil)
        pdata.bot_target_generation = generation
    end

    if pdata.bot_target then
        local controls, still_useful = steer_towards(pos, dir, pdata.bot_target)
        if still_useful then
            return controls
        end
        pdata.bot_target = nil -- path blocked - give up on this one, same as opportunistic
    end

    return decide_passive(pos, dir)
end

-- Bots aim independently of their body facing now (the turret can point
-- anywhere, same as a player's free mouse-look - see movement.lua), so
-- shooting is no longer restricted to "an enemy dead ahead in my lane."
-- Instead: find the nearest enemy within SHOOT_RANGE, point the turret
-- straight at them, and only actually fire if a simple line-of-sight walk
-- says nothing solid is in the way. Still a "dumb" check - no bounce-shot
-- prediction, no aiming lead on a moving target - matching the tank AI's
-- stated goal of starting simple.
local SHOOT_RANGE = 10
local LOS_STEP = 0.5

local function nearest_enemy_pos_in_range(self_pdata, pos, range)
    local best_pos, best_dist_sq = nil, range * range
    for _, other_pdata in pairs(battletanks.players) do
        if other_pdata ~= self_pdata and other_pdata.alive and other_pdata.tank_obj then
            local other_pos = other_pdata.tank_obj:get_pos()
            if other_pos then
                local dx, dz = other_pos.x - pos.x, other_pos.z - pos.z
                local d = dx * dx + dz * dz
                if d <= best_dist_sq then
                    best_pos, best_dist_sq = { x = other_pos.x, y = pos.y, z = other_pos.z }, d
                end
            end
        end
    end
    return best_pos
end

-- Walks from pos to target in small (sub-node) steps checking for solid
-- nodes in between - unlike path_clear above, this needs to work along an
-- arbitrary angle (the target isn't necessarily on a cardinal direction
-- from the shooter), so it steps by a fixed short distance rather than one
-- whole node at a time, to avoid skipping past a thin wall at a shallow
-- angle.
local function has_line_of_sight(pos, target)
    local dx, dz = target.x - pos.x, target.z - pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < LOS_STEP then return true end
    local dir = { x = dx / dist, y = 0, z = dz / dist }
    local steps = math.floor(dist / LOS_STEP)
    for step = 1, steps do
        local check = vector.round(vector.add(pos, vector.multiply(dir, step * LOS_STEP)))
        check.y = S.arena_center.y + 1
        if is_hazard_node(minetest.get_node(check).name) then
            return false
        end
    end
    return true
end

function battletanks.bots.get_controls(pdata, pos, dir)
    local controls
    if pdata.bot_behavior == "opportunistic" then
        controls = decide_opportunistic(pdata, pos, dir)
    elseif pdata.bot_behavior == "aggressive" then
        controls = decide_aggressive(pdata, pos, dir)
    else
        controls = decide_passive(pos, dir)
    end

    -- Movement is player/bot-gated now (see movement.lua) rather than
    -- forced - a bot needs to explicitly hold "up" to actually drive.
    -- Keep it moving forward at all times, unless a decide_* function
    -- above explicitly asked to hold position (controls.up == false,
    -- e.g. an aggressive bot already at its engagement range) - nil just
    -- means "didn't have an opinion," which defaults to "keep driving."
    if controls.up == nil then
        controls.up = true
    end

    if pdata.boost and pdata.boost > 0 then
        controls.sneak = true -- boost is triggered by the boost key now, not by "up" (see movement.lua)
    end

    local enemy_pos = nearest_enemy_pos_in_range(pdata, pos, SHOOT_RANGE)
    local can_shoot = false
    if enemy_pos then
        local dx, dz = enemy_pos.x - pos.x, enemy_pos.z - pos.z
        pdata.bot_turret_yaw = minetest.dir_to_yaw({ x = dx, y = 0, z = dz })
        can_shoot = has_line_of_sight(pos, enemy_pos)
    else
        pdata.bot_turret_yaw = nil -- nothing to aim at - movement.lua falls back to body facing
    end

    if can_shoot and pdata.laser and pdata.laser > 0
        and (not pdata.laser_cooldown_remaining or pdata.laser_cooldown_remaining <= 0) then
        controls.jump = true
    elseif can_shoot and pdata.rocket and pdata.rocket > 0
        and (not pdata.rocket_cooldown_remaining or pdata.rocket_cooldown_remaining <= 0) then
        controls.aux1 = true
    end

    return controls
end
