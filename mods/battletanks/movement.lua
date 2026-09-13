
local S = battletanks.settings
local HALF_PI = math.pi / 2

function battletanks.enter_battle_physics(player)
    player:set_physics_override({
        speed = 1, jump = 0, gravity = 0, sneak = false, sneak_glitch = false,
    })
end

local function snap_to_grid(obj, offset)
    local pos = obj:get_pos()
    if pos then
        local rounded = vector.round(pos)
        if offset then
            rounded = vector.add(rounded, offset)
        end
        obj:set_pos(rounded)
    end
end

local function is_hazard_node(node_name)
    local node_def = minetest.registered_nodes[node_name]
    return minetest.get_item_group(node_name, "battletanks_wall") == 1
        or (node_def and node_def.walkable)
end

-- Where a shot fired from `start_pos` along `dir` (horizontal, unit
-- vector) would actually hit - the first wall/obstacle cell, or the point
-- at S.crosshair_max_range if nothing's in the way. Used to place the
-- world-anchored crosshair exactly at the shot's true impact point (see
-- hud.lua's update_crosshair) rather than at some arbitrary fixed
-- distance, which reads as noticeably wrong up close due to parallax
-- between the camera (above the tank) and the shot's actual height.
local CROSSHAIR_STEP = 0.5

local function crosshair_target_point(start_pos, dir)
    local steps = math.floor(S.crosshair_max_range / CROSSHAIR_STEP)
    for step = 1, steps do
        local sample = vector.add(start_pos, vector.multiply(dir, step * CROSSHAIR_STEP))
        local rounded = vector.round(sample)
        rounded.y = S.arena_center.y + 1
        if is_hazard_node(minetest.get_node(rounded).name) then
            return sample
        end
    end
    return vector.add(start_pos, vector.multiply(dir, S.crosshair_max_range))
end

minetest.register_globalstep(function(dtime)
    local phase = lobby_system.state.phase
    -- Players already exist and have a turret during "countdown" (spawning
    -- happens before the countdown starts - see lobby_system's
    -- start_one_player/run_countdown), so this runs then too, not just once
    -- "playing" begins - otherwise the turret can't track a player's free-
    -- look until GO!, and instead visibly snaps to catch up the instant it
    -- does. Actual driving and firing stay gated to "playing" via
    -- racing_active below.
    if phase ~= "playing" and phase ~= "countdown" then return end
    if battletanks.paused then return end

    local racing_active = phase == "playing"

    local to_eliminate = {}

    for name, pdata in pairs(battletanks.players) do
        if (lobby_system.state.phase ~= "playing" and lobby_system.state.phase ~= "countdown")
            or not pdata.racing then break end

        if pdata.alive and pdata.tank_obj then
            local player = pdata.is_bot and nil or minetest.get_player_by_name(name)
            local obj = pdata.tank_obj
            if obj and obj:get_pos() and (pdata.is_bot or (player and player:is_player())) then
                local controls
                if pdata.is_bot then
                    local pos_now = obj:get_pos()
                    local dir_now = minetest.yaw_to_dir(pdata.yaw)
                    controls = battletanks.bots.get_controls(pdata, pos_now, dir_now, name)
                else
                    controls = player:get_player_control()
                end

                if racing_active then
                    -- Body turning: still 90-degree locked and edge-
                    -- triggered, same as lightcycles - only the "always
                    -- moving" assumption elsewhere is what's new for tanks.
                    -- Held off until "playing" (not during countdown), same
                    -- as driving/firing below.
                    local tank_off = battletanks.settings.tank_attach_offset
                    if controls.left and not pdata.was_left then
                        pdata.yaw = pdata.yaw + HALF_PI
                        snap_to_grid(obj, tank_off)
                        battletanks.sync_turret_to_body(pdata) -- body position just jumped outside normal velocity integration - see the comment on this function
                    end
                    if controls.right and not pdata.was_right then
                        pdata.yaw = pdata.yaw - HALF_PI
                        snap_to_grid(obj, tank_off)
                        battletanks.sync_turret_to_body(pdata)
                    end
                    pdata.was_left = controls.left
                    pdata.was_right = controls.right
                    pdata.yaw = pdata.yaw % (2 * math.pi)
                    obj:set_yaw(pdata.yaw)
                end

                -- Turret aim: for a human player this follows their actual
                -- mouse-look, independent of the body's cardinal-locked
                -- yaw - the one genuinely new mechanical idea in Battle
                -- Tanks (see the conversion notes). Bots don't have a
                -- camera, but they can still aim independently of their
                -- body facing - bots.lua works out an angle toward the
                -- nearest in-range, line-of-sight enemy and leaves it on
                -- pdata.bot_turret_yaw; falls back to the body facing when
                -- there's nothing to aim at. Runs during the countdown too
                -- (see the note at the top of this function) - only firing
                -- is held back until "playing".
                local turret_yaw = pdata.yaw
                if player then
                    turret_yaw = player:get_look_horizontal()
                    -- World-anchored crosshair (see hud.lua's
                    -- add_crosshair/update_crosshair) - placed at the
                    -- actual point a shot would hit right now, along the
                    -- turret's horizontal-only aim, at the exact height a
                    -- shot travels at. No vertical component, ever -
                    -- matching the turret and its shots.
                    local body_pos_now = obj:get_pos()
                    if body_pos_now then
                        local aim_dir = minetest.yaw_to_dir(turret_yaw)
                        local shot_origin = { x = body_pos_now.x, y = S.arena_center.y + 1, z = body_pos_now.z }
                        local aim_point = crosshair_target_point(shot_origin, aim_dir)
                        battletanks.hud.update_crosshair(player, aim_point)
                    end
                elseif pdata.bot_turret_yaw then
                    turret_yaw = pdata.bot_turret_yaw
                end
                pdata.turret_yaw = turret_yaw
                if pdata.turret_obj then
                    -- Yaw only here - velocity is matched further down,
                    -- after the movement block below has actually set the
                    -- body's velocity for *this* tick. Doing it here
                    -- instead would read the body's velocity from the
                    -- *previous* tick (this tick's hasn't been decided
                    -- yet), putting the turret one tick behind every time
                    -- the body starts, stops, reverses, or turns - which
                    -- is exactly what caused the rubber-banding.
                    pdata.turret_obj:set_yaw(turret_yaw)
                end

                if not racing_active then
                    -- Countdown: turret tracking above still runs, but
                    -- nothing else does yet.
                    goto continue
                end

                -- Movement: player-gated and 4-direction-locked (forward or
                -- backward along the body's own facing - no free strafing),
                -- replacing lightcycles' forced-always-forward drive. This
                -- is the other big movement.lua change: driving is now
                -- "hold a direction, move that way; release, stop."
                local dir = minetest.yaw_to_dir(pdata.yaw)
                local move_dir = nil
                local is_reverse = false
                if controls.up then
                    move_dir = dir
                elseif controls.down then
                    move_dir = vector.multiply(dir, -1)
                    is_reverse = true
                end

                -- Boost: a free-standing "hold to go faster" resource,
                -- consumed by the boost key (sneak/Shift - freed up now
                -- that the camera no longer needs it to look behind, since
                -- free turret look already covers that). Only refills via
                -- a boost powerup pickup (see powerups.lua) - it does NOT
                -- regenerate over time, unlike lightcycles' brake-to-charge.
                -- Requires move_dir (actually driving) so holding Shift
                -- while standing still doesn't drain the bar for no effect.
                local boosting = move_dir ~= nil and controls.sneak and pdata.boost > 0
                local speed_mult = 1.0
                local pitch_state = "normal"
                if boosting then
                    speed_mult = 1 + S.boost_delta
                    pitch_state = "boost"
                    pdata.boost = math.max(0, pdata.boost - (100 / S.boost_time) * dtime)
                end
                if is_reverse then
                    speed_mult = speed_mult * S.reverse_speed_multiplier
                    if pitch_state == "normal" then pitch_state = "reverse" end
                end

                if move_dir then
                    if pitch_state ~= pdata.engine_pitch_state then
                        pdata.engine_pitch_state = pitch_state
                        local pitch = (S.sound["engine_pitch_" .. pitch_state]) or S.sound.engine_pitch_normal
                        battletanks.sounds.set_engine_pitch(obj, name, pitch)
                    end
                elseif pdata.engine_pitch_state then
                    -- Was moving, isn't any more - the loop sound should
                    -- only play while actually driving, not idling.
                    pdata.engine_pitch_state = nil
                    battletanks.sounds.stop_engine_loop(name)
                end

                if player then
                    battletanks.hud.update_boost_bar(player, pdata.boost)
                    battletanks.hud.update_speed(player, move_dir
                        and (controls.down and -(speed_mult * 100) or speed_mult * 100) or 0)
                end

                local pos = obj:get_pos()

                if move_dir then
                    local speed = S.base_speed * speed_mult
                    -- Must cover at least as far as the tank is about to
                    -- travel this tick (speed * dtime), not just a fixed
                    -- distance - a fixed S.move_check_ahead can check less
                    -- far than the tank is about to move whenever
                    -- speed*dtime exceeds it, which is already true at
                    -- ordinary tick rates once boost is factored in
                    -- (S.move_check_ahead=0.35 vs. up to ~7.8 nodes/sec of
                    -- boosted speed), and worse under any server slowdown
                    -- that stretches dtime out further - letting the tank
                    -- travel past what was actually verified clear before
                    -- the next tick's check catches up, i.e. overshooting
                    -- into a wall instead of stopping cleanly at its edge.
                    -- The original S.move_check_ahead value is kept as a
                    -- flat margin on top, for some buffer even at low
                    -- speed (e.g. reverse).
                    local check_dist = speed * dtime + S.move_check_ahead
                    local ahead = vector.add(pos, vector.multiply(move_dir, check_dist))
                    local ahead_rounded = vector.round(ahead)
                    ahead_rounded.y = S.arena_center.y + 1
                    local node = minetest.get_node(ahead_rounded)
                    local is_wall = is_hazard_node(node.name)
                    local is_pit = battletanks.is_pit(ahead_rounded.x, ahead_rounded.z)

                    local is_tank_ahead = false
                    for other_name, other_pdata in pairs(battletanks.players) do
                        if other_name ~= name and other_pdata.alive and other_pdata.tank_obj then
                            local other_pos = other_pdata.tank_obj:get_pos()
                            if other_pos then
                                local other_rounded = vector.round(other_pos)
                                if other_rounded.x == ahead_rounded.x and other_rounded.z == ahead_rounded.z then
                                    is_tank_ahead = true
                                    break
                                end
                            end
                        end
                    end

                    if is_pit then
                        -- A gap in the floor is still lethal, same as
                        -- lightcycles - unlike a wall or another tank
                        -- (below), there's nothing to "just stop" against.
                        table.insert(to_eliminate, name)
                        obj:set_velocity({ x = 0, y = 0, z = 0 })
                    elseif is_wall or is_tank_ahead then
                        -- Driving into a wall or another tank simply stops
                        -- you - no elimination, no destroyed terrain. Only
                        -- a shot can derez someone now (see projectiles.lua).
                        obj:set_velocity({ x = 0, y = 0, z = 0 })
                    else
                        obj:set_velocity({ x = move_dir.x * speed, y = 0, z = move_dir.z * speed })
                    end
                else
                    obj:set_velocity({ x = 0, y = 0, z = 0 })
                end

                if pdata.turret_obj then
                    -- Not a real engine attachment - see entity.lua's
                    -- spawn_turret comment on why (attached objects ignore
                    -- position/rotation setters, which would make
                    -- independent aiming impossible). Instead this just
                    -- matches the body's own velocity - now that the body's
                    -- velocity is actually finalized for this tick (the
                    -- block just above) - which is what keeps it moving
                    -- smoothly in lockstep. Doing this every tick instead
                    -- of a per-tick set_pos() is what avoids visibly
                    -- stepping/bumping along: an explicit position write
                    -- gets sent to clients as a teleport each time rather
                    -- than something they can interpolate between the way
                    -- matched velocity is.
                    pdata.turret_obj:set_velocity(obj:get_velocity())
                end

                pos.y = S.arena_center.y + 1

                if pdata.laser_cooldown_remaining and pdata.laser_cooldown_remaining > 0 then
                    pdata.laser_cooldown_remaining = pdata.laser_cooldown_remaining - dtime
                end
                if (controls.dig or controls.jump) and pdata.laser and pdata.laser > 0
                    and (not pdata.laser_cooldown_remaining or pdata.laser_cooldown_remaining <= 0) then
                    pdata.laser = pdata.laser - 1
                    pdata.laser_cooldown_remaining = S.laser_cooldown
                    battletanks.fire_laser(name, pos, turret_yaw)
                    if player then
                        battletanks.hud.update_laser(player, pdata.laser)
                    end
                    minetest.chat_send_all("[BattleTanks] " .. name .. " fired a shot! (" .. pdata.laser .. " left)")
                end

                if pdata.rocket_cooldown_remaining and pdata.rocket_cooldown_remaining > 0 then
                    pdata.rocket_cooldown_remaining = pdata.rocket_cooldown_remaining - dtime
                end
                if (controls.aux1 or controls.place) and pdata.rocket and pdata.rocket > 0
                    and (not pdata.rocket_cooldown_remaining or pdata.rocket_cooldown_remaining <= 0) then
                    pdata.rocket = pdata.rocket - 1
                    pdata.rocket_cooldown_remaining = S.rocket_cooldown
                    battletanks.fire_rocket(name, pos, turret_yaw)
                    if player then
                        battletanks.hud.update_rocket(player, pdata.rocket)
                    end
                    minetest.chat_send_all("[BattleTanks] " .. name .. " fired a rocket! (" .. pdata.rocket .. " left)")
                end

                battletanks.check_powerup_pickup(name, pdata, pos)
            end
        end

        ::continue::
    end

    if #to_eliminate > 0 then
        battletanks.eliminate_batch(to_eliminate)
    end
end)
