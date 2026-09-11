-- ===================== PROJECTILES =====================
-- Not tied to any one racer's own per-tick loop
-- (movement.lua) - projectiles are independent entities with their own
-- short lifetime, tracked in battletanks.projectiles and updated by this
-- file's own globalstep, the same way powerup spawn/expiry timers run
-- independently of the main racer loop.
--

local S = battletanks.settings

battletanks.projectiles = {} -- { { obj=, shooter_name=, spawn_us=, kind="laser"|"rocket", last_pos=, trail_spawner= (rocket only) }, ... }

-- How close (nodes) a bolt needs to be to a tank to count as a hit - a
-- plain distance check against the tank's own current position, not a
-- node-based check the way wall/boundary collision works, since a moving
-- tank isn't grid-aligned to a single cell the way a wall node is.
local HIT_RADIUS = 0.6

-- If `name` is currently holding a shield charge, consumes one and returns
-- true (the hit is absorbed - no elimination, no score for the shooter).
-- Otherwise returns false and does nothing. This is shield's new job in
-- Battle Tanks: lightcycles used it to let you break through a trail wall,
-- but there's no trail wall left to break through, so it's been retargeted
-- at "block one incoming shot" instead - same charge count, same HUD, same
-- shield_break sound/effect, just a different trigger.
local function try_shield_block(name, hit_pos)
    local pdata = battletanks.players[name]
    if not pdata or not pdata.shield or pdata.shield <= 0 then return false end
    pdata.shield = pdata.shield - 1
    battletanks.hud.update_shield(minetest.get_player_by_name(name), pdata.shield)
    battletanks.sounds.play_shield_break(hit_pos)
    battletanks.spawn_crash_effect(hit_pos, pdata.color)
    minetest.chat_send_all("[BattleTanks] " .. name .. "'s shield absorbed a hit! (" .. pdata.shield .. " left)")
    return true
end

minetest.register_entity("battletanks:laser_bolt", {
    initial_properties = {
        visual = "cube",
        visual_size = { x = 0.35, y = 0.35, z = 1.4 }, -- elongated along its direction of travel
        textures = {
            "battletanks_laser_projectile.png", "battletanks_laser_projectile.png",
            "battletanks_laser_projectile.png", "battletanks_laser_projectile.png",
            "battletanks_laser_projectile.png", "battletanks_laser_projectile.png",
        },
        physical = false, -- driven entirely by our own velocity/collision handling below, not engine physics
        pointable = false, -- not something a player can punch/select
        static_save = false, -- never persisted - always either mid-match or already gone
        glow = 14,
        collide_with_objects = false,
    },
})

minetest.register_entity("battletanks:rocket", {
    initial_properties = {
        visual = "cube",
        visual_size = { x = 0.35, y = 0.35, z = 1.4 }, -- elongated along its direction of travel
        textures = {
            "battletanks_rocket_projectile.png", "battletanks_rocket_projectile.png",
            "battletanks_rocket_projectile.png", "battletanks_rocket_projectile.png",
            "battletanks_rocket_projectile.png", "battletanks_rocket_projectile.png",
        },
        physical = false, -- driven entirely by our own velocity/collision handling below, not engine physics
        pointable = false, -- not something a player can punch/select
        static_save = false, -- never persisted - always either mid-match or already gone
        glow = 14,
        collide_with_objects = false,
    },
})

-- Fires a shot from pos, heading along yaw (the shooter's *turret* yaw,
-- not necessarily their body's cardinal facing - see movement.lua), on
-- behalf of `name`. Doesn't check laser/cooldown itself - movement.lua
-- already did before calling this, exactly like check_powerup_pickup
-- expects its caller to have already decided a pickup is happening.
function battletanks.fire_laser(name, pos, yaw)
    local dir = minetest.yaw_to_dir(yaw)
    -- Spawned a little ahead of the shooter's own position, not exactly on
    -- top of it - otherwise the very first hit-check below could catch the
    -- shooter's own tank before the bolt has moved anywhere at all.
    local spawn_pos = vector.add(pos, vector.multiply(dir, 1.2))
    spawn_pos.y = pos.y

    local obj = minetest.add_entity(spawn_pos, "battletanks:laser_bolt")
    if not obj then return end
    obj:set_yaw(yaw)
    local speed = S.base_speed * S.laser_speed_multiplier
    obj:set_velocity({ x = dir.x * speed, y = 0, z = dir.z * speed })

    table.insert(battletanks.projectiles, {
        obj = obj,
        shooter_name = name,
        spawn_us = minetest.get_us_time(),
        kind = "laser",
        last_pos = spawn_pos,
        bounce_count = 0,
    })

    battletanks.sounds.play_shoot_laser(pos)
end

-- Fires a rocket from pos, heading along yaw, on behalf of `name`. Doesn't
-- check rocket ammo/cooldown itself, same contract as fire_laser above -
-- movement.lua (or bots.lua's decision, consumed the same way) already
-- decided a shot is happening before calling this.
function battletanks.fire_rocket(name, pos, yaw)
    local dir = minetest.yaw_to_dir(yaw)
    local spawn_pos = vector.add(pos, vector.multiply(dir, 1.2))
    spawn_pos.y = pos.y

    local obj = minetest.add_entity(spawn_pos, "battletanks:rocket")
    if not obj then return end
    obj:set_yaw(yaw)
    local speed = S.base_speed * S.rocket_speed_multiplier
    obj:set_velocity({ x = dir.x * speed, y = 0, z = dir.z * speed })

    -- A little red sparkle trail behind the rocket as it flies - a
    -- particlespawner "attached" to the rocket's own entity, which makes
    -- Luanti re-spawn particles at wherever the rocket currently is every
    -- tick, rather than this file having to track/update a position
    -- itself. time = 0 means "continuous, no fixed end" (runs for as long
    -- as the spawner exists), with `amount` then read as particles/second
    -- instead of "total particles over `time`". Reuses the rocket's own
    -- projectile texture (colorized red, in case the source art isn't
    -- already a pure red) rather than shipping a dedicated spark asset -
    -- same "reuse what's already there" trick spawn_crash_effect uses for
    -- its own particles.
    local trail_spawner = minetest.add_particlespawner({
        attached = obj,
        time = 0,
        amount = 30,
        minpos = { x = 0, y = 0, z = 0 },
        maxpos = { x = 0, y = 0, z = 0 },
        minvel = { x = -0.4, y = -0.2, z = -0.4 },
        maxvel = { x = 0.4, y = 0.4, z = 0.4 },
        minacc = { x = 0, y = -1, z = 0 },
        maxacc = { x = 0, y = -1, z = 0 },
        minexptime = 0.15,
        maxexptime = 0.35,
        minsize = 0.6,
        maxsize = 1.2,
        texture = "battletanks_rocket_projectile.png^[colorize:red:140",
        glow = 14,
        collisiondetection = false,
    })

    table.insert(battletanks.projectiles, {
        obj = obj,
        shooter_name = name,
        spawn_us = minetest.get_us_time(),
        kind = "rocket",
        trail_spawner = trail_spawner,
        last_pos = spawn_pos,
        bounce_count = 0,
    })

    battletanks.sounds.play_shoot_rocket(pos)
end

-- How far (in grid cells, each direction) a rocket's blast reaches from
-- its impact cell - 1 means the impact cell plus its 8 neighbors, a 3x3
-- area, matching the design ask of "9 blocks total". Only matters for
-- tanks caught in the blast now - walls aren't destroyed by it any more
-- than they are by a direct laser hit (see bounce_off_wall).
local BLAST_RADIUS = 1

-- Eliminates (or shield-blocks) any racer standing in the 3x3 area
-- centered on `center`, awarding the shooter a kill bonus for each racer
-- actually eliminated. shooter_name is excluded from the splash-kill check
-- (same as a direct hit already can't be the shooter's own tank - see
-- fire_laser/fire_rocket's forward spawn offset) - self-splash off your
-- own rocket would punish exactly the shots most likely to be fired
-- defensively, at point-blank range, against something bearing down on
-- you.
local function explode_rocket(center, shooter_name)
    local cx, cz = center.x, center.z
    local y = S.arena_center.y + 1
    battletanks.sounds.play_rocket_explosion({ x = cx, y = y, z = cz })
    battletanks.spawn_rocket_blast_effect({ x = cx, y = y, z = cz })

    for dx = -BLAST_RADIUS, BLAST_RADIUS do
        for dz = -BLAST_RADIUS, BLAST_RADIUS do
            local p = { x = cx + dx, y = y, z = cz + dz }

            for rname, pdata in pairs(battletanks.players) do
                if pdata.alive and pdata.tank_obj and rname ~= shooter_name then
                    local cpos = pdata.tank_obj:get_pos()
                    if cpos then
                        local rp = vector.round(cpos)
                        if rp.x == p.x and rp.z == p.z then
                            if not try_shield_block(rname, p) then
                                local shooter_pdata = battletanks.players[shooter_name]
                                if shooter_pdata and shooter_pdata.alive then
                                    lobby_system.add_score(shooter_name, S.kill_by_shot_points)
                                    shooter_pdata.battle_score = shooter_pdata.battle_score + S.kill_by_shot_points
                                    lobby_system.hud.update_all_scoreboards()
                                    battletanks.hud.update_battle_table()
                                end
                                battletanks.eliminate(rname, rname .. " was derezzed by " .. shooter_name
                                    .. "'s rocket! (+" .. S.kill_by_shot_points .. " for " .. shooter_name .. ")")
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Reflects a laser bolt off an axis-aligned wall it just ran into, instead
-- of destroying anything (the real new physics Battle Tanks needed - see
-- the conversion notes; rockets don't bounce at all, see the wall-hit
-- branch above). Since the turret aims freely, a bolt's direction of
-- travel isn't itself locked to 90 degrees the way tank movement is, so
-- this can't just assume it hit head-on: it compares the two "half-step"
-- cells straddling the collision (one sharing the bolt's old X with its
-- new Z, one sharing its old Z with its new X) to work out whether an X-
-- facing wall, a Z-facing wall, or a corner was struck, and negates the
-- matching velocity component(s). The bolt's own yaw is then re-aligned to
-- match the new velocity direction - otherwise the model keeps pointing
-- the way it was originally fired while visibly flying off at an angle.
-- The bolt is also stepped back to its last known-clear position first, so
-- it doesn't keep re-triggering the same collision next tick before the
-- reflected velocity has carried it clear of the wall.
--
-- Capped at S.laser_max_bounces: once a bolt has bounced that many times
-- without hitting anything, this returns false instead of bouncing again,
-- so the caller can despawn it - a bolt that just keeps ricocheting
-- forever would otherwise be possible on an enclosed layout.
--
-- `prev` is the last clear point along this tick's swept path (see
-- sweep_hit below), not just wherever the bolt happened to be a whole
-- tick ago - using the precise pre-collision point keeps the reflection
-- accurate even when several nodes were swept through in a single step.
local function bounce_off_wall(p, hit_rounded, prev)
    p.bounce_count = (p.bounce_count or 0) + 1
    if p.bounce_count > S.laser_max_bounces then
        return false
    end

    local obj = p.obj
    local prev_rounded = vector.round(prev)

    local function hazard_at(pos)
        local node = minetest.get_node(pos)
        local node_def = minetest.registered_nodes[node.name]
        return minetest.get_item_group(node.name, "battletanks_wall") == 1
            or (node_def and node_def.walkable)
    end

    local y = hit_rounded.y
    local x_side_hazard = hazard_at({ x = hit_rounded.x, y = y, z = prev_rounded.z })
    local z_side_hazard = hazard_at({ x = prev_rounded.x, y = y, z = hit_rounded.z })

    local vel = obj:get_velocity()
    if x_side_hazard and not z_side_hazard then
        vel.x = -vel.x
    elseif z_side_hazard and not x_side_hazard then
        vel.z = -vel.z
    else
        -- Corner hit (or ambiguous) - bounce back the way it came.
        vel.x = -vel.x
        vel.z = -vel.z
    end
    obj:set_velocity(vel)
    if vel.x ~= 0 or vel.z ~= 0 then
        obj:set_yaw(minetest.dir_to_yaw(vel))
    end
    obj:set_pos(prev)
    p.last_pos = prev
    return true
end

-- Removes every currently-active bolt outright (no impact effects) -
-- called at match end, the same "stop everything mid-flight" cleanup
-- trail walls/bots/powerups all get.
function battletanks.clear_all_projectiles()
    for _, p in ipairs(battletanks.projectiles) do
        if p.obj then
            pcall(function() p.obj:remove() end)
        end
        if p.trail_spawner then
            pcall(function() minetest.delete_particlespawner(p.trail_spawner) end)
        end
    end
    battletanks.projectiles = {}
end

-- How finely (in nodes) to sample a projectile's path this tick when
-- checking for what it ran into. A laser bolt moves several nodes per
-- server step (base_speed * laser_speed_multiplier, divided by the
-- server's tick rate) - only checking its position once, at the *end* of
-- the tick, can skip clean over a single-node-thick wall (like the arena
-- boundary) it passed through along the way, which is exactly what caused
-- shots to fly through the outer wall. Sampling well inside one node
-- apart makes that reliable regardless of speed.
local SWEEP_STEP = 0.25

-- Walks the straight line from `prev` to `cur` in SWEEP_STEP increments,
-- checking each sample point for a tank hit or a hazard node - whichever
-- comes first along the path wins, rather than only looking at where the
-- projectile ended up this tick. Returns nil if the whole segment is
-- clear, or a table describing what got hit:
--   { kind = "tank", name = <racer name>, pos = <sample point> }
--   { kind = "wall", pos = <rounded hazard cell> }
-- Either way also returns `last_clear`, the last sample point before the
-- hit (or `prev` itself if the very first sample already hit) - used to
-- give bounce_off_wall a precise pre-collision position to reflect from.
local function sweep_hit(p, prev, cur)
    local allow_self = (p.bounce_count or 0) > 0
    local dx, dz = cur.x - prev.x, cur.z - prev.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local steps = math.max(1, math.ceil(dist / SWEEP_STEP))
    local last_clear = prev

    for i = 1, steps do
        local t = i / steps
        local sample = { x = prev.x + dx * t, y = cur.y, z = prev.z + dz * t }

        for rname, pdata in pairs(battletanks.players) do
            if pdata.alive and pdata.tank_obj and (rname ~= p.shooter_name or allow_self) then
                local cpos = pdata.tank_obj:get_pos()
                if cpos and vector.distance(sample, cpos) < HIT_RADIUS then
                    return { kind = "tank", name = rname, pos = sample }, last_clear
                end
            end
        end

        local rounded = vector.round(sample)
        rounded.y = S.arena_center.y + 1
        local node = minetest.get_node(rounded)
        local node_def = minetest.registered_nodes[node.name]
        if minetest.get_item_group(node.name, "battletanks_wall") == 1 or (node_def and node_def.walkable) then
            return { kind = "wall", pos = rounded }, last_clear
        end

        last_clear = sample
    end

    return nil, last_clear
end

minetest.register_globalstep(function(dtime)
    if lobby_system.state.phase ~= "playing" then return end
    if battletanks.paused then return end -- see pause.lua - a bolt shouldn't keep flying (or hit anything) while the match is supposedly frozen
    if #battletanks.projectiles == 0 then return end

    for i = #battletanks.projectiles, 1, -1 do
        local p = battletanks.projectiles[i]
        local obj = p.obj
        local remove_this = false

        if not obj or not obj:get_pos() then
            remove_this = true
        else
            local pos = obj:get_pos()
            local prev = p.last_pos or pos
            local hit, last_clear = sweep_hit(p, prev, pos)

            if hit and hit.kind == "tank" then
                local hit_name = hit.name
                if p.kind == "rocket" then
                    -- Blast centered on the hit racer's own exact tank
                    -- position (not the sample point, which could be up
                    -- to HIT_RADIUS away). If the direct target's own
                    -- shield blocks this hit, the rocket fizzles
                    -- harmlessly - no blast at all, same as a shielded
                    -- laser hit below.
                    local hit_pdata = battletanks.players[hit_name]
                    local hit_pos = hit_pdata and hit_pdata.tank_obj and hit_pdata.tank_obj:get_pos()
                    local rounded_hit_pos = vector.round(hit_pos or hit.pos)
                    if not try_shield_block(hit_name, rounded_hit_pos) then
                        explode_rocket(rounded_hit_pos, p.shooter_name)
                    end
                else
                    if not try_shield_block(hit_name, hit.pos) then
                        if hit_name == p.shooter_name then
                            -- Accidental suicide off your own bounced shot -
                            -- no kill bonus for derezzing yourself.
                            battletanks.eliminate(hit_name, hit_name
                                .. " was derezzed by their own ricocheting laser!")
                        else
                            local shooter_pdata = battletanks.players[p.shooter_name]
                            if shooter_pdata and shooter_pdata.alive then
                                lobby_system.add_score(p.shooter_name, S.kill_by_shot_points)
                                shooter_pdata.battle_score = shooter_pdata.battle_score + S.kill_by_shot_points
                                lobby_system.hud.update_all_scoreboards()
                                battletanks.hud.update_battle_table()
                            end
                            battletanks.eliminate(hit_name, hit_name .. " was derezzed by " .. p.shooter_name
                                .. "'s laser! (+" .. S.kill_by_shot_points .. " for " .. p.shooter_name .. ")")
                        end
                    end
                end
                remove_this = true
            elseif hit and hit.kind == "wall" then
                -- Wall hits: a laser bolt bounces off any boundary or
                -- maze-obstacle node (see bounce_off_wall) - nothing about
                -- a wall is destroyed by a laser. A rocket, though, still
                -- detonates against a wall exactly like it would against a
                -- tank (see explode_rocket) - it just doesn't have a tank
                -- at the center of the blast this time.
                if p.kind == "rocket" then
                    explode_rocket(hit.pos, p.shooter_name)
                    remove_this = true
                elseif not bounce_off_wall(p, hit.pos, last_clear) then
                    remove_this = true -- hit its bounce cap (S.laser_max_bounces) - give up on it
                end
            end

            local lifetime = p.kind == "rocket" and S.rocket_lifetime or S.laser_lifetime
            if not remove_this and (minetest.get_us_time() - p.spawn_us) / 1000000 > lifetime then
                remove_this = true -- traveled long enough without hitting anything - give up on it
            end

            if not remove_this and obj then
                p.last_pos = obj:get_pos()
            end
        end

        if remove_this then
            if obj then pcall(function() obj:remove() end) end
            -- Deleting the particlespawner explicitly rather than relying
            -- on it stopping on its own once the attached object is gone:
            -- an "attached" spawner with time = 0 has no natural end of
            -- its own, so leaving this out would leak one live,
            -- perpetually-emitting-nothing spawner per rocket for the
            -- rest of the server's uptime.
            if p.trail_spawner then
                pcall(function() minetest.delete_particlespawner(p.trail_spawner) end)
            end
            table.remove(battletanks.projectiles, i)
        end
    end
end)
