
battletanks.bots = {}

local S = battletanks.settings

local function now_seconds()
    return minetest.get_us_time() / 1000000
end

local function set_bot_state(pdata, state)
    if pdata.bot_state == state then return end
    pdata.bot_state = state
    if S.bot_debug_logging then
        minetest.log("action", "[BattleTanks] " .. (pdata.name or "?")
            .. " (" .. (pdata.bot_behavior or "?") .. "): " .. state)
    end
end

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

local function powerup_still_at(target)
    local check = vector.round(target)
    check.y = S.arena_center.y + 1
    local n = minetest.get_node(check).name
    return n == "battletanks:powerup_point" or n == "battletanks:powerup_boost"
        or n == "battletanks:powerup_shield" or n == "battletanks:powerup_laser"
        or n == "battletanks:powerup_rocket"
end

local function adjacent_powerup_side(prev_pos, pos, dir, ignore_cell)
    local left_dir = { x = -dir.z, y = 0, z = dir.x }
    local right_dir = { x = dir.z, y = 0, z = -dir.x }
    local ignore_rounded = ignore_cell and vector.round(ignore_cell)

    local function safe_to_swerve(side_dir, cell)
        local powerup_cell = vector.round(vector.add(cell, side_dir))
        if ignore_rounded and powerup_cell.x == ignore_rounded.x and powerup_cell.z == ignore_rounded.z then
            return false
        end
        if not powerup_still_at(powerup_cell) then return false end
        local beyond = vector.round(vector.add(powerup_cell, side_dir))
        beyond.y = S.arena_center.y + 1
        return not is_hazard_or_pit_at(beyond)
    end

    local SWEEP_STEP = 0.5
    local dx, dz = pos.x - prev_pos.x, pos.z - prev_pos.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local steps = math.min(40, math.max(1, math.ceil(dist / SWEEP_STEP))) -- capped defensively - normal per-tick movement never gets close to this
    local last_cell = nil

    for step = 0, steps do
        local t = step / steps
        local sample = { x = prev_pos.x + dx * t, y = pos.y, z = prev_pos.z + dz * t }
        local cell = vector.round(sample)
        if not last_cell or cell.x ~= last_cell.x or cell.z ~= last_cell.z then
            last_cell = cell
            if safe_to_swerve(left_dir, cell) then return "left" end
            if safe_to_swerve(right_dir, cell) then return "right" end
        end
    end

    return nil
end

local SWERVE_LOCK_DURATION = 1.0

local function decide_direction(pdata, pos, dir, target)
    if pdata.turn_tiebreak_left == nil then
        pdata.turn_tiebreak_left = math.random() < 0.5
    end

    local swerve = adjacent_powerup_side(pdata.swerve_prev_pos or pos, pos, dir, target)
    if swerve then
        set_bot_state(pdata, "swerving for a powerup")
        pdata.swerve_lock_until = now_seconds() + SWERVE_LOCK_DURATION
        return { [swerve] = true }
    end

    local left_dir = { x = -dir.z, y = 0, z = dir.x }
    local right_dir = { x = dir.z, y = 0, z = -dir.x }

    if target then
        local dx, dz = target.x - pos.x, target.z - pos.z
        local target_dist = math.sqrt(dx * dx + dz * dz)
        local check_dist = math.max(1, math.min(LOOKAHEAD, math.ceil(target_dist)))

        if path_clear(pos, dir, check_dist) and (dir.x * dx + dir.z * dz) > 0 then
            return {}
        end
        if path_clear(pos, left_dir, check_dist) and (left_dir.x * dx + left_dir.z * dz) > 0 then
            return { left = true }
        end
        if path_clear(pos, right_dir, check_dist) and (right_dir.x * dx + right_dir.z * dz) > 0 then
            return { right = true }
        end
    end

    local straight_clear = path_clear(pos, dir, LOOKAHEAD)
    local left_clear = path_clear(pos, left_dir, LOOKAHEAD)
    local right_clear = path_clear(pos, right_dir, LOOKAHEAD)

    if straight_clear then
        return {}
    elseif left_clear and right_clear then
        return pdata.turn_tiebreak_left and { left = true } or { right = true }
    elseif left_clear then
        return { left = true }
    elseif right_clear then
        return { right = true }
    end

    return nil -- boxed in on every side
end

local function decide_passive(pdata, pos, dir)
    local controls = battletanks.bots.seek_point_powerup(pdata, pos, dir)
    if controls then return controls end

    set_bot_state(pdata, "wandering")

    return decide_direction(pdata, pos, dir, nil)
        or (math.random() < 0.5 and { left = true } or { right = true }) -- boxed in - stuck-escape will sort it out if this doesn't help either
end

local function find_nearest_powerup(pos, range)
    local best_pos, best_type, best_dist_sq = nil, nil, range and (range * range) or math.huge

    local function consider(p, ptype)
        if not p then return end
        local dx, dz = p.x - pos.x, p.z - pos.z
        local d = dx * dx + dz * dz
        if d <= best_dist_sq then
            best_pos, best_type, best_dist_sq = p, ptype, d
        end
    end

    for _, p in ipairs(battletanks.get_active_point_powerup_positions()) do
        consider(p, "point")
    end
    for _, p in ipairs(battletanks.get_active_boost_powerup_positions()) do
        consider(p, "boost")
    end
    for _, p in ipairs(battletanks.get_active_shield_powerup_positions()) do
        consider(p, "shield")
    end
    for _, p in ipairs(battletanks.get_active_laser_powerup_positions()) do
        consider(p, "laser")
    end
    for _, p in ipairs(battletanks.get_active_rocket_powerup_positions()) do
        consider(p, "rocket")
    end

    return best_pos, best_type
end

local function find_nearest_point_powerup(pos)
    local best_pos, best_dist_sq = nil, math.huge
    for _, p in ipairs(battletanks.get_active_point_powerup_positions()) do
        local dx, dz = p.x - pos.x, p.z - pos.z
        local d = dx * dx + dz * dz
        if d < best_dist_sq then
            best_pos, best_dist_sq = p, d
        end
    end
    return best_pos
end

local function find_nearest_ammo_powerup(pos)
    local best_pos, best_dist_sq = nil, math.huge
    local function consider(p)
        if not p then return end
        local dx, dz = p.x - pos.x, p.z - pos.z
        local d = dx * dx + dz * dz
        if d < best_dist_sq then
            best_pos, best_dist_sq = p, d
        end
    end
    for _, p in ipairs(battletanks.get_active_laser_powerup_positions()) do
        consider(p)
    end
    for _, p in ipairs(battletanks.get_active_rocket_powerup_positions()) do
        consider(p)
    end
    return best_pos
end

local function find_nearest_shield_powerup(pos)
    local best_pos, best_dist_sq = nil, math.huge
    for _, p in ipairs(battletanks.get_active_shield_powerup_positions()) do
        local dx, dz = p.x - pos.x, p.z - pos.z
        local d = dx * dx + dz * dz
        if d < best_dist_sq then
            best_pos, best_dist_sq = p, d
        end
    end
    return best_pos
end

local function steer_towards(pdata, pos, dir, target)
    local dx = target.x - pos.x
    local dz = target.z - pos.z
    if math.abs(dx) < 0.5 and math.abs(dz) < 0.5 then
        return { up = false }, true
    end

    local controls = decide_direction(pdata, pos, dir, target)
    if controls then
        return controls, true
    end
    return nil, false -- boxed in on every side - genuinely nothing to do here
end

function battletanks.bots.seek_point_powerup(pdata, pos, dir)
    if pdata.point_target and not powerup_still_at(pdata.point_target) then
        pdata.point_target = nil -- collected/expired before we got there
    end

    if not pdata.point_target then
        pdata.point_target = find_nearest_point_powerup(pos)
    end

    if pdata.point_target then
        local controls, still_useful = steer_towards(pdata, pos, dir, pdata.point_target)
        if still_useful then
            set_bot_state(pdata, "chasing point powerup")
            return controls
        end
        pdata.point_target = nil -- path blocked - give up on this one
    end

    return nil -- no reachable point powerup to aim for right now
end

local function decide_opportunistic(pdata, pos, dir)
    if pdata.bot_target and not powerup_still_at(pdata.bot_target) then
        pdata.bot_target = nil -- collected/expired before we got there
    end

    if not pdata.bot_target then
        pdata.bot_target, pdata.bot_target_type = find_nearest_powerup(pos, OPPORTUNISTIC_RANGE)
    end

    if pdata.bot_target then
        local controls, still_useful = steer_towards(pdata, pos, dir, pdata.bot_target)
        if still_useful then
            set_bot_state(pdata, "chasing nearby " .. (pdata.bot_target_type or "powerup") .. " powerup")
            return controls
        end
        pdata.bot_target = nil -- path blocked - give up on this one, same as "obstacle encountered"
    end

    return decide_passive(pdata, pos, dir)
end

local function find_nearest_enemy_pos(self_pdata, pos)
    local best_pos, best_name, best_dist_sq = nil, nil, math.huge
    for other_name, other_pdata in pairs(battletanks.players) do
        if other_pdata ~= self_pdata and other_pdata.alive and other_pdata.tank_obj then
            local other_pos = other_pdata.tank_obj:get_pos()
            if other_pos then
                local dx, dz = other_pos.x - pos.x, other_pos.z - pos.z
                local d = dx * dx + dz * dz
                if d < best_dist_sq then
                    best_pos, best_name, best_dist_sq = { x = other_pos.x, y = pos.y, z = other_pos.z }, other_name, d
                end
            end
        end
    end
    return best_pos, best_name
end

local LOS_STEP = 0.5

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

local ENGAGEMENT_RANGE = 3

local MIN_ENGAGEMENT_RANGE = 2

local function seek_cached(pdata, pos, dir, cache_key, finder)
    if pdata[cache_key] and not powerup_still_at(pdata[cache_key]) then
        pdata[cache_key] = nil -- collected/expired before we got there
    end

    if not pdata[cache_key] then
        pdata[cache_key] = finder(pos)
    end

    if pdata[cache_key] then
        local controls, still_useful = steer_towards(pdata, pos, dir, pdata[cache_key])
        if still_useful then
            return controls
        end
        pdata[cache_key] = nil -- path blocked - give up on this one
    end

    return nil
end

local function decide_aggressive(pdata, pos, dir)
    local total_ammo = (pdata.laser or 0) + (pdata.rocket or 0)

    if total_ammo < S.bot_low_ammo_threshold then
        local controls = seek_cached(pdata, pos, dir, "ammo_target", find_nearest_ammo_powerup)
        if controls then
            set_bot_state(pdata, "seeking ammo (" .. total_ammo .. " left)")
            return controls
        end
    end

    if not (pdata.shield and pdata.shield > 0) then
        local controls = seek_cached(pdata, pos, dir, "shield_target", find_nearest_shield_powerup)
        if controls then
            set_bot_state(pdata, "seeking shield")
            return controls
        end
    end

    if total_ammo > 0 then
        local enemy_pos, enemy_name = find_nearest_enemy_pos(pdata, pos)
        if enemy_pos then
            local dx, dz = enemy_pos.x - pos.x, enemy_pos.z - pos.z
            local dist_sq = dx * dx + dz * dz

            if dist_sq < MIN_ENGAGEMENT_RANGE * MIN_ENGAGEMENT_RANGE then
                local dist = math.sqrt(dist_sq)
                local away_dir = dist > 0.01 and { x = -dx / dist, y = 0, z = -dz / dist } or dir
                local flee_point = vector.add(pos, vector.multiply(away_dir, ENGAGEMENT_RANGE + 2))
                local controls, still_useful = steer_towards(pdata, pos, dir, flee_point)
                if still_useful then
                    set_bot_state(pdata, "backing off from " .. (enemy_name or "enemy"))
                    return controls
                end
            end

            if dist_sq <= ENGAGEMENT_RANGE * ENGAGEMENT_RANGE and has_line_of_sight(pos, enemy_pos) then
                local controls = steer_towards(pdata, pos, dir, enemy_pos)
                controls.up = false
                set_bot_state(pdata, "engaging " .. (enemy_name or "enemy"))
                return controls
            end

            local controls, still_useful = steer_towards(pdata, pos, dir, enemy_pos)
            if still_useful then
                set_bot_state(pdata, "hunting " .. (enemy_name or "enemy"))
                return controls
            end
        end
    end

    if pdata.bot_target and not powerup_still_at(pdata.bot_target) then
        pdata.bot_target = nil -- reached/collected/expired
    end

    local generation = battletanks.powerup_spawn_generation
    if not pdata.bot_target or pdata.bot_target_generation ~= generation then
        pdata.bot_target, pdata.bot_target_type = find_nearest_powerup(pos, nil)
        pdata.bot_target_generation = generation
    end

    if pdata.bot_target then
        local controls, still_useful = steer_towards(pdata, pos, dir, pdata.bot_target)
        if still_useful then
            set_bot_state(pdata, "chasing " .. (pdata.bot_target_type or "powerup") .. " (no target to fight)")
            return controls
        end
        pdata.bot_target = nil -- path blocked - give up on this one, same as opportunistic
    end

    return decide_passive(pdata, pos, dir)
end


local function nearest_enemy_pos_in_range(self_pdata, pos, range)
    local best_pos, best_name, best_dist_sq = nil, nil, range * range
    for name, other_pdata in pairs(battletanks.players) do
        if other_pdata ~= self_pdata and other_pdata.alive and other_pdata.tank_obj then
            local other_pos = other_pdata.tank_obj:get_pos()
            if other_pos then
                local dx, dz = other_pos.x - pos.x, other_pos.z - pos.z
                local d = dx * dx + dz * dz
                if d <= best_dist_sq then
                    best_pos, best_name, best_dist_sq = { x = other_pos.x, y = pos.y, z = other_pos.z }, name, d
                end
            end
        end
    end
    return best_pos, best_name
end

local STUCK_TIME = 2.0             -- seconds without meaningful movement before triggering
local STUCK_MOVE_THRESHOLD = 0.3   -- nodes; movement below this still counts as "stuck"
local STUCK_REVERSE_DISTANCE = 3   -- nodes to back up before turning
local STUCK_REVERSE_TIMEOUT = 3.0  -- safety cap (seconds) in case reversing is also blocked

local POST_ESCAPE_LOCK_DURATION = 1.5

local function update_stuck_escape(pdata, pos)
    local now = now_seconds()

    if not pdata.stuck_ref_pos or vector.distance(pos, pdata.stuck_ref_pos) > STUCK_MOVE_THRESHOLD then
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now
        return
    end

    if now - pdata.stuck_ref_time >= STUCK_TIME then
        pdata.stuck_escape_phase = "reversing"
        pdata.stuck_escape_start_pos = pos
        pdata.stuck_escape_deadline = now + STUCK_REVERSE_TIMEOUT
        pdata.stuck_escape_dir = math.random() < 0.5 and "left" or "right"
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now
    end
end

local function apply_boost_and_shoot(pdata, pos, controls)
    if pdata.boost and pdata.boost > 0 then
        controls.sneak = true -- boost is triggered by the boost key now, not by "up" (see movement.lua)
    end

    local enemy_pos, enemy_name = nearest_enemy_pos_in_range(pdata, pos, battletanks.settings.bot_shoot_range)
    local has_los = false
    if enemy_pos then
        local dx, dz = enemy_pos.x - pos.x, enemy_pos.z - pos.z
        pdata.bot_turret_yaw = minetest.dir_to_yaw({ x = dx, y = 0, z = dz })
        has_los = has_line_of_sight(pos, enemy_pos)
    else
        pdata.bot_turret_yaw = nil -- nothing to aim at - movement.lua falls back to body facing
    end

    local can_shoot = false
    if has_los then
        if pdata.aim_lock_target ~= enemy_name or not pdata.aim_lock_start then
            pdata.aim_lock_target = enemy_name
            pdata.aim_lock_start = now_seconds()
        elseif now_seconds() - pdata.aim_lock_start >= S.bot_shoot_delay then
            can_shoot = true
        end
    else
        pdata.aim_lock_target = nil
        pdata.aim_lock_start = nil
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

local function abandon_all_targets(pdata)
    pdata.point_target = nil
    pdata.bot_target = nil
    pdata.ammo_target = nil
    pdata.shield_target = nil
end

function battletanks.bots.get_controls(pdata, pos, dir, name)
    pdata.name = name

    if pdata.stuck_escape_phase == "reversing" then
        set_bot_state(pdata, "stuck - backing up")
        local traveled = vector.distance(pos, pdata.stuck_escape_start_pos)
        if traveled < STUCK_REVERSE_DISTANCE and now_seconds() < pdata.stuck_escape_deadline then
            return apply_boost_and_shoot(pdata, pos, { down = true })
        end
        pdata.stuck_escape_phase = "turning" -- backed up far enough (or timed out trying) - turn next
    end

    if pdata.stuck_escape_phase == "turning" then
        set_bot_state(pdata, "stuck - turning to escape")
        pdata.stuck_escape_phase = nil
        abandon_all_targets(pdata)
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now_seconds()
        pdata.post_escape_lock_until = now_seconds() + POST_ESCAPE_LOCK_DURATION
        return apply_boost_and_shoot(pdata, pos, { [pdata.stuck_escape_dir] = true, up = true })
    end

    if pdata.post_escape_lock_until and now_seconds() < pdata.post_escape_lock_until then
        if path_clear(pos, dir, LOOKAHEAD) then
            set_bot_state(pdata, "recovering after stuck")
            return apply_boost_and_shoot(pdata, pos, { up = true })
        end
        pdata.post_escape_lock_until = nil -- turned out to be blocked too - let normal decision-making take over
    end

    if pdata.swerve_lock_until and now_seconds() < pdata.swerve_lock_until then
        if path_clear(pos, dir, 1) then
            set_bot_state(pdata, "swerving for a powerup")
            return apply_boost_and_shoot(pdata, pos, { up = true })
        end
        pdata.swerve_lock_until = nil -- turned out to be blocked too - let normal decision-making take over
    end

    local controls
    if pdata.bot_behavior == "opportunistic" then
        controls = decide_opportunistic(pdata, pos, dir)
    elseif pdata.bot_behavior == "aggressive" then
        controls = decide_aggressive(pdata, pos, dir)
    else
        controls = decide_passive(pdata, pos, dir)
    end
    pdata.swerve_prev_pos = pos -- for adjacent_powerup_side's sweep, next tick

    if controls.up == nil then
        controls.up = true
    end

    if lobby_system.state.phase == "playing" and controls.up then
        update_stuck_escape(pdata, pos)
    else
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now_seconds()
        pdata.stuck_escape_phase = nil
    end

    return apply_boost_and_shoot(pdata, pos, controls)
end
