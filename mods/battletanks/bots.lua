
battletanks.bots = {}

local S = battletanks.settings

local function now_seconds()
    return minetest.get_us_time() / 1000000
end

-- Debugging aid (see settings.lua's bot_debug_logging, off by default) -
-- logs to the server log (not chat, so it never spams players) whenever a
-- bot's high-level intent changes, so "why did it just do that" can be
-- answered by reading the log afterward instead of having to guess from
-- watching behavior alone. Deliberately only logs on an actual *change* of
-- state, not every tick - logging every tick for every bot would be
-- enormous and useless. `pdata.name` is set once per tick in get_controls.
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

-- How far ahead (nodes) every strategic wall-check in this file looks
-- before deciding a direction is safe to commit to. Used to be 3, which
-- turned out to not be nearly enough buffer: at base_speed with boost
-- (~7.8 nodes/sec) a single tick can already cover more than a node, and
-- under any server slowdown - more likely the busier a match gets, e.g.
-- several bots all doing this same computation during a firefight - a
-- tick can cover much more than that. A wall sitting just past the old
-- 3-node range would go completely undetected until it was already close
-- enough that there were only one or two ticks left to react, which
-- wasn't reliably enough to turn away in time. It also happened to
-- exactly equal STUCK_REVERSE_DISTANCE (also 3) below, which caused its
-- own specific bug: backing up exactly as far as the detection range let
-- a bot "see" the very wall it just fled from as clear again, immediately
-- walking back into it - see the comment on STUCK_REVERSE_DISTANCE and
-- POST_ESCAPE_LOCK_DURATION.
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

-- Cheap "don't drive right past free stuff" check: if a powerup happens
-- to be sitting in the cell immediately to the bot's left or right, turn
-- straight toward it. Rounds to the bot's current cell first rather than
-- using its raw, continuously-changing position - that's what fixed an
-- earlier jitter bug here, where a fractional position could flicker in
-- and out of detecting the very same powerup as the bot inched forward,
-- producing repeated contradictory turns. Deliberately a direct turn, not
-- routed through the general LOOKAHEAD-node clearance check everything
-- else uses: that's meant for committing to several nodes of travel
-- toward a distant target, and is far too strict for a target that's
-- only ever 1 node away - if anything at all sits 2-3 nodes past the
-- powerup (extremely common; powerups often sit near a wall or in a
-- small alcove), that check would judge the whole direction "unsafe" and
-- refuse to turn, even though the powerup itself is perfectly reachable.
--
-- Still checks one node past the powerup, though - not zero: a powerup
-- tucked right up against a wall (also extremely common) would otherwise
-- turn the bot straight into that wall the instant it reaches the
-- powerup. One extra node of clearance catches that specific case without
-- being as over-strict as the full multi-node check would be.
--
-- `ignore_cell` excludes one specific powerup from consideration -
-- decide_direction passes its own current target here. Without that, a bot
-- driving straight at a target it's *already* deliberately heading for
-- would see that same powerup become "adjacent" during the final approach
-- (dead ahead isn't exactly the same cell as beside, right up until the
-- last step) and swerve for it - fighting with the ordinary target-seeking
-- logic over the exact same goal, tick after tick, since each swerve turn
-- changes the heading enough that the target then reads as adjacent again
-- from the new angle. Excluding the current target here isn't a loss - the
-- bot was already headed straight for it anyway.
--
-- Checked directly inside decide_direction (below), not as a separate
-- bolted-on check consulted only when the main decision left things
-- "neutral" - and not locked in afterward the way an earlier version of
-- this needed to be, since that was only ever a workaround for
-- decide_direction's old wrong-reference-frame bug reversing it a tick
-- later; the fixed version naturally leaves the bot facing the powerup
-- once it turns, and re-evaluating fresh next tick correctly finds
-- nothing left to swerve for.
local function adjacent_powerup_side(prev_pos, pos, dir, ignore_cell)
    local left_dir = { x = -dir.z, y = 0, z = dir.x }
    local right_dir = { x = dir.z, y = 0, z = -dir.x }
    local ignore_rounded = ignore_cell and vector.round(ignore_cell)

    local function safe_to_swerve(side_dir, cell)
        local powerup_cell = vector.round(vector.add(cell, side_dir))
        -- x/z only, deliberately: powerup_cell's y comes from the sweep's
        -- sample point (the bot's own current elevation), not from the
        -- powerup's actual placement height, so comparing all three axes
        -- via vector.equals could fail to match ignore_cell even when x/z
        -- line up exactly - this whole check only ever cares about the
        -- horizontal grid position anyway.
        if ignore_rounded and powerup_cell.x == ignore_rounded.x and powerup_cell.z == ignore_rounded.z then
            return false
        end
        if not powerup_still_at(powerup_cell) then return false end
        local beyond = vector.round(vector.add(powerup_cell, side_dir))
        beyond.y = S.arena_center.y + 1
        return not is_hazard_or_pit_at(beyond)
    end

    -- Samples the path between last tick's position and this tick's,
    -- rather than only the current instantaneous cell, in case a single
    -- tick's movement covers more than a full node - easily possible
    -- while boosting or under any server slowdown. Checking only the
    -- current cell could skip clean over the one row where an adjacent
    -- powerup would've been detected, exactly the way a fast-moving
    -- projectile can skip past a target between two single-point checks -
    -- see projectiles.lua's sweep_hit, which this mirrors.
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

-- The core steering rule, used by every behavior whether it's actively
-- pursuing a target or just wandering (target == nil):
--   1. Never drive into a wall or pit - if going straight is blocked
--      within LOOKAHEAD nodes, turn instead.
--   2. Never turn toward a wall or pit either - a turn candidate that's
--      itself blocked isn't a valid choice.
--   3. Prefer whichever safe direction actually makes progress toward
--      `target`, if one is given.
--   4. If neither safe direction makes progress (or there's no target),
--      there is no other preference. This is a deliberate simplification
--      from an earlier version of this file: LightCycles favored turning
--      toward more open space, to leave itself more room to maneuver
--      around its own trail, and that heuristic (measure_openness,
--      find_wall_gap_distance) got carried over here even though
--      BattleTanks has no trail and no equivalent reason to prefer one
--      open direction over another - every safe direction is exactly as
--      good as any other. That heuristic's own borderline comparisons
--      (which side has *slightly* more open floor, or finds a gap one
--      step sooner) were themselves the root cause of several of the
--      worst bugs here (see BOT_AI.md): they needed increasingly
--      elaborate commitment/hysteresis machinery just to stop their own
--      near-ties from flip-flopping, and that machinery is what actually
--      broke (wrong reference frames after a turn, mismatched commitment
--      durations between layers, etc). Removing the preference removes
--      the comparison entirely, which removes the entire category of
--      problem - there's nothing left that can be unstable. Each bot gets
--      a fixed, random-at-spawn tiebreak_left so an otherwise-symmetric
--      choice is still deterministic and stable for that specific bot (no
--      per-tick randomness, no oscillation risk), without every bot
--      making the identical choice in a symmetric situation.
-- How long a triggered swerve commits to its chosen direction before
-- anything else (specifically, whatever target-pursuit logic called
-- decide_direction with a *different* target) is allowed to override it -
-- see the swerve rule's own comment inside decide_direction for why this
-- is necessary again despite the redesign that removed the original
-- version of this lock.
local SWERVE_LOCK_DURATION = 1.0

local function decide_direction(pdata, pos, dir, target)
    if pdata.turn_tiebreak_left == nil then
        pdata.turn_tiebreak_left = math.random() < 0.5
    end

    -- Rule: grab a powerup immediately beside the path, unless swerving
    -- for it isn't actually safe (adjacent_powerup_side's own job) - ahead
    -- of target-pursuit below, so a bot doesn't pass up something free
    -- just because it was already turning toward a farther-off goal. The
    -- current target itself is excluded (see adjacent_powerup_side's
    -- comment) - the bot's already heading straight for it.
    --
    -- Also sets a brief lock (see get_controls, SWERVE_LOCK_DURATION):
    -- this powerup is *not* the current target, so on the very next tick
    -- the target-pursuit logic below would see the swerve's turn as having
    -- moved away from its own goal and turn straight back - putting this
    -- same powerup adjacent again and re-triggering the swerve, forever.
    -- Committing to the swerve for a moment lets it actually finish before
    -- target-pursuit gets a chance to fight it over which way is correct.
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
        -- Only need to verify the path is clear as far as the target
        -- itself, not the full LOOKAHEAD - a target closer than LOOKAHEAD
        -- (the normal case once actually approaching one) can easily have
        -- something else within that longer range without that being in
        -- the way of reaching the target at all. Point powerups in
        -- particular are frequently placed at the end of a dead-end
        -- alcove as an exploration reward - the alcove's own back wall,
        -- sitting just past the target, would otherwise make the full
        -- LOOKAHEAD check fail and turn the bot away consistently (via
        -- turn_tiebreak_left, so not randomly - a deliberate-looking
        -- "avoidance") even though getting to the target itself, a couple
        -- of nodes short of that wall, was never actually unsafe.
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

    -- Below this point there's no target-specific goal left to reach (or
    -- the checks above found no safe way to make progress toward it this
    -- tick), so fall back to plain obstacle avoidance using the full
    -- LOOKAHEAD - there's no short-range destination to cap the check at
    -- any more.
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

-- Point powerups only, unrelated range (in practice, a maze is usually
-- small enough that "unlimited" just means "anywhere on the map"). Point
-- powerups are placed as part of the level itself rather than expiring
-- like the others, which makes them a sensible standing objective for a
-- bot to navigate a maze toward even when nothing else is nearby - unlike
-- boost/shield/laser/rocket, which are worth grabbing opportunistically
-- but not worth crossing the whole map for.
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

-- Laser or rocket, whichever's closer - used by decide_aggressive when
-- running low on ammo (see bot_low_ammo_threshold), unrelated range for
-- the same reason as find_nearest_point_powerup above.
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

-- Thin wrapper around decide_direction that adds the one thing specific
-- to chasing a point-like target: recognizing "we've basically arrived."
local function steer_towards(pdata, pos, dir, target)
    local dx = target.x - pos.x
    local dz = target.z - pos.z
    if math.abs(dx) < 0.5 and math.abs(dz) < 0.5 then
        -- Close enough that pickup detection (check_powerup_pickup, which
        -- checks the tank's own rounded position every tick regardless of
        -- what this function decides) will catch it on its own - hold
        -- here rather than continuing forward. Point powerups are level
        -- content and are often placed at the end of a dead-end alcove as
        -- an exploration reward, meaning there's frequently a wall
        -- directly behind the target - blindly continuing forward here
        -- drove the bot straight through the pickup and into that wall.
        return { up = false }, true
    end

    local controls = decide_direction(pdata, pos, dir, target)
    if controls then
        return controls, true
    end
    return nil, false -- boxed in on every side - genuinely nothing to do here
end

-- Shared by both decide_passive (directly) and decide_opportunistic (as a
-- fallback once nothing's within its own short range) - keeps its own
-- cached target on pdata.point_target, separate from pdata.bot_target
-- (used for opportunistic's short-range "any powerup" target and
-- aggressive's enemy/powerup target) so the two don't second-guess each
-- other's in-progress goal.
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

    -- Nothing within OPPORTUNISTIC_RANGE right now - rather than just
    -- wandering, head for the nearest point powerup anywhere on the map
    -- (decide_passive's job below), giving a maze-shaped level something
    -- concrete to navigate toward instead of only reacting to whatever
    -- happens to already be nearby.
    return decide_passive(pdata, pos, dir)
end

-- The "dumb version" hunt behavior called for in the conversion notes:
-- drive toward the nearest other alive tank's current position, no real
-- pathfinding - if steer_towards can't make progress this tick (path
-- blocked), fall through to powerup-seeking/wandering below instead of
-- getting stuck. Recomputed fresh every tick (unlike powerup targets,
-- which are cached until collected/expired) since enemy tanks are always
-- moving.
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

-- Walks from pos to target in small (sub-node) steps checking for solid
-- nodes in between - unlike path_clear above, this needs to work along an
-- arbitrary angle (the target isn't necessarily on a cardinal direction
-- from the shooter), so it steps by a fixed short distance rather than one
-- whole node at a time, to avoid skipping past a thin wall at a shallow
-- angle.
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

-- Tanks aren't melee weapons: an aggressive bot stops closing in once it's
-- within this many nodes of its target, instead of shoving its barrel into
-- the enemy's rear bumper. It'll still turn to line up a shot at that
-- range - see decide_aggressive - just without driving any closer.
local ENGAGEMENT_RANGE = 3

-- If two bots (or a bot and a player) are both closing in on each other
-- at once, checking the distance only once per tick, before that tick's
-- movement happens, isn't enough to reliably stop right at
-- ENGAGEMENT_RANGE - their combined closing speed can carry them past it
-- within a single tick, and by the time the check reflects that they're
-- already too close, "holding position" at a too-close distance doesn't
-- actually create any breathing room. Falling below this tighter
-- threshold triggers an active back-off instead of just holding - see
-- decide_aggressive.
local MIN_ENGAGEMENT_RANGE = 2

-- Shared by the ammo/shield-seeking priorities below - keeps its own
-- cached target under pdata[cache_key], separate from pdata.bot_target
-- (the generic "any powerup" fallback further down) and pdata.point_target
-- (decide_passive's), so none of them second-guess each other's
-- in-progress goal.
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

    -- Priority 1: resupply ammo once running low (not just completely
    -- dry) - see bot_low_ammo_threshold. Ammo outranks shields here since
    -- a bot that can't shoot back is far less useful than one that can
    -- take a hit or two without a shield.
    if total_ammo < S.bot_low_ammo_threshold then
        local controls = seek_cached(pdata, pos, dir, "ammo_target", find_nearest_ammo_powerup)
        if controls then
            set_bot_state(pdata, "seeking ammo (" .. total_ammo .. " left)")
            return controls
        end
    end

    -- Priority 2: pick up a shield if completely out of them.
    if not (pdata.shield and pdata.shield > 0) then
        local controls = seek_cached(pdata, pos, dir, "shield_target", find_nearest_shield_powerup)
        if controls then
            set_bot_state(pdata, "seeking shield")
            return controls
        end
    end

    -- Priority 3: hunt, same as before - only actually worth doing with
    -- at least one shot left; see the ammo-seeking branch above for what
    -- happens otherwise (also covers the case where the map has simply
    -- run out of ammo powerups to find).
    if total_ammo > 0 then
        local enemy_pos, enemy_name = find_nearest_enemy_pos(pdata, pos)
        if enemy_pos then
            local dx, dz = enemy_pos.x - pos.x, enemy_pos.z - pos.z
            local dist_sq = dx * dx + dz * dz

            if dist_sq < MIN_ENGAGEMENT_RANGE * MIN_ENGAGEMENT_RANGE then
                -- Way too close, most likely from both sides closing in
                -- fast at once (see MIN_ENGAGEMENT_RANGE's comment) -
                -- actively back off to a safer distance rather than just
                -- holding still right on top of the other tank. Aims for
                -- a point straight out past the ideal standoff distance,
                -- in whichever direction is already away from the
                -- threat, and reuses the same steer_towards logic
                -- everything else does to actually get there - more
                -- reliable than picking a random direction, since this is
                -- guaranteed to move away from the *actual* threat rather
                -- than a coin flip that could just as easily go straight
                -- at it.
                local dist = math.sqrt(dist_sq)
                local away_dir = dist > 0.01 and { x = -dx / dist, y = 0, z = -dz / dist } or dir
                local flee_point = vector.add(pos, vector.multiply(away_dir, ENGAGEMENT_RANGE + 2))
                local controls, still_useful = steer_towards(pdata, pos, dir, flee_point)
                if still_useful then
                    set_bot_state(pdata, "backing off from " .. (enemy_name or "enemy"))
                    return controls
                end
                -- Boxed in even for backing off - fall through to
                -- holding/aiming instead, since there's nowhere to flee to.
            end

            -- Straight-line distance alone isn't enough here: a wall
            -- between the bot and the enemy can easily put them within
            -- ENGAGEMENT_RANGE nodes as the crow flies while there's no
            -- way to actually hit anything through it. Without also
            -- checking line of sight, a bot in that spot would decide
            -- it's "close enough" and hold position - i.e. stop dead
            -- behind the wall - forever, since it can never get a shot
            -- from there. Requiring line of sight before holding means it
            -- keeps trying to path closer (below) instead.
            if dist_sq <= ENGAGEMENT_RANGE * ENGAGEMENT_RANGE and has_line_of_sight(pos, enemy_pos) then
                -- Close enough with a clear shot - hold this distance.
                -- Still turn to line up a shot if steer_towards thinks
                -- that'd help, but never move forward toward the target
                -- from here.
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
            -- Blocked this tick - fall through to powerup-seeking/wandering
            -- below rather than trying to shove through a wall.
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

-- Bots aim independently of their body facing now (the turret can point
-- anywhere, same as a player's free mouse-look - see movement.lua), so
-- shooting is no longer restricted to "an enemy dead ahead in my lane."
-- Instead: find the nearest enemy within bot_shoot_range, point the turret
-- straight at them, and only actually fire if a simple line-of-sight walk
-- (has_line_of_sight, above) says nothing solid is in the way. Still a
-- "dumb" check - no bounce-shot prediction, no aiming lead on a moving
-- target - matching the tank AI's stated goal of starting simple.

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

-- Stuck detection: if a bot's tank hasn't actually moved more than a
-- small tolerance in this long, its steering logic above presumably isn't
-- resolving whatever it ran into - e.g. driving straight into a corner
-- that needs a full U-turn, which none of decide_passive's single-90-
-- degree-turn logic accounts for. This is a last-resort unstick, not a
-- replacement for that logic: back up a few nodes to get clear of
-- whatever it's touching, then commit to a random turn and continue - if
-- that's still not enough, it'll trigger again.
local STUCK_TIME = 2.0             -- seconds without meaningful movement before triggering
local STUCK_MOVE_THRESHOLD = 0.3   -- nodes; movement below this still counts as "stuck"
local STUCK_REVERSE_DISTANCE = 3   -- nodes to back up before turning
local STUCK_REVERSE_TIMEOUT = 3.0  -- safety cap (seconds) in case reversing is also blocked

-- After the escape's turn, commit to driving straight in that new
-- direction for this long, rather than letting normal decision-making
-- reconsider it immediately. Without this, backing up STUCK_REVERSE_DISTANCE
-- nodes and turning could still walk straight back into the very wall
-- just escaped: from the new, backed-up position, a fresh check of the
-- *original* direction can find it "clear" again simply because backing
-- up moved the wall outside checking range - a target re-selected right
-- back in that direction (or even plain wall-avoidance re-evaluating
-- from scratch) could then turn straight back toward it, having gained
-- nothing from backing up at all. Only held onto as long as the new
-- direction is actually still drivable (re-checked every tick) - if that
-- turns out to be blocked too, this gives up immediately rather than
-- insisting on it, which would otherwise just trade one stuck wall for
-- another.
local POST_ESCAPE_LOCK_DURATION = 1.5

-- Only meaningful while the bot is actually trying to drive - an
-- aggressive bot deliberately holding its engagement range on purpose
-- (controls.up == false - see decide_aggressive) genuinely isn't moving,
-- but that's not "stuck," so the caller only invokes this when it is
-- trying to move this tick, and clears the tracking otherwise. Triggering
-- starts the "reversing" phase of the escape - see get_controls below for
-- how that hands off to the "turning" phase once it's backed up enough.
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
        -- Reset the reference point/timer too, so this doesn't instantly
        -- retrigger while the escape is already in progress.
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now
    end
end

-- Shared by every return path in get_controls below (normal decisions and
-- both escape phases alike) so boosting and shooting keep working the
-- same regardless of what's driving the movement/turn part of controls.
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

    -- A clear shot alone doesn't mean fire immediately: a bot needs to
    -- hold a continuous line of sight on the *same* target for
    -- bot_shoot_delay seconds first, simulating the moment a human needs to
    -- actually aim rather than instantly snapping on target the frame it
    -- becomes visible. Losing sight, or the nearest enemy changing to a
    -- different racer, resets the buildup - re-acquiring takes the full
    -- delay again, same as losing your aim on a target that ducked
    -- behind cover would for a person. This matters most in open areas,
    -- where a player has room to break sight before the delay runs out;
    -- in a tight corridor there's usually nowhere to go anyway, so it
    -- makes less difference there.
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

-- Cleared whenever a stuck-escape maneuver actually fires (see
-- get_controls' "turning" phase below) - every long-range or cached
-- target a bot might currently be committed to, across every behavior.
-- Getting stuck isn't just "briefly blocked" (that resolves on its own
-- every tick via the normal steering above) - it means 2 full seconds
-- passed without meaningful progress toward whatever it was heading for,
-- which is a real sign that particular target needs actual pathfinding
-- to reach (e.g. it requires a detour around something like the outer
-- boundary) that this "dumb," purely local/greedy steering was never
-- meant to solve. Without clearing it, the bot would go right back to
-- attempting the exact same doomed approach the instant the escape
-- finished, likely getting stuck again shortly after - which is what
-- turned a single failed approach into what looked like several seconds
-- of jittering.
local function abandon_all_targets(pdata)
    pdata.point_target = nil
    pdata.bot_target = nil
    pdata.ammo_target = nil
    pdata.shield_target = nil
end

function battletanks.bots.get_controls(pdata, pos, dir, name)
    pdata.name = name

    -- An escape maneuver in progress overrides normal decision-making
    -- entirely, in either of its two phases (see update_stuck_escape for
    -- how "reversing" gets triggered).
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
        -- Give it a fresh, full STUCK_TIME window before this could
        -- possibly trigger again, rather than measuring from whenever the
        -- original escape started.
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now_seconds()
        pdata.post_escape_lock_until = now_seconds() + POST_ESCAPE_LOCK_DURATION
        return apply_boost_and_shoot(pdata, pos, { [pdata.stuck_escape_dir] = true, up = true })
    end

    -- Commit to the escape's chosen direction for a bit after the turn
    -- above, rather than letting normal decision-making reconsider it
    -- immediately - see POST_ESCAPE_LOCK_DURATION's comment for why.
    -- Re-checked every tick: only holds as long as continuing straight
    -- (in whatever direction the escape's turn left the bot facing) is
    -- still actually clear.
    if pdata.post_escape_lock_until and now_seconds() < pdata.post_escape_lock_until then
        if path_clear(pos, dir, LOOKAHEAD) then
            set_bot_state(pdata, "recovering after stuck")
            return apply_boost_and_shoot(pdata, pos, { up = true })
        end
        pdata.post_escape_lock_until = nil -- turned out to be blocked too - let normal decision-making take over
    end

    -- A swerve in progress also overrides normal decision-making, briefly -
    -- see decide_direction's swerve rule for why: without this, whatever
    -- target-pursuit is currently active (hunting an enemy, seeking a
    -- shield, etc.) would see the swerve's turn as having moved away from
    -- its own goal and turn straight back next tick - putting the same
    -- powerup adjacent again and re-triggering the swerve forever.
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

    -- Movement is player/bot-gated now (see movement.lua) rather than
    -- forced - a bot needs to explicitly hold "up" to actually drive.
    -- Keep it moving forward at all times, unless a decide_* function
    -- above explicitly asked to hold position (controls.up == false,
    -- e.g. an aggressive bot already at its engagement range) - nil just
    -- means "didn't have an opinion," which defaults to "keep driving."
    if controls.up == nil then
        controls.up = true
    end

    -- Only tracked once movement is actually possible - during the
    -- pre-match countdown, decide_* already runs (so a bot is correctly
    -- oriented and aiming the instant "GO!" hits, the same reason turret
    -- aiming already works during countdown), but movement itself is
    -- frozen until then. Without this check, that frozen countdown looked
    -- identical to being wedged against a wall, and the stuck-escape would
    -- already be mid-recovery before the match even started.
    if lobby_system.state.phase == "playing" and controls.up then
        update_stuck_escape(pdata, pos)
    else
        -- Deliberately holding position this tick, not stuck - don't let
        -- an escape order started earlier linger into the next time it
        -- does try to drive.
        pdata.stuck_ref_pos = pos
        pdata.stuck_ref_time = now_seconds()
        pdata.stuck_escape_phase = nil
    end

    return apply_boost_and_shoot(pdata, pos, controls)
end
