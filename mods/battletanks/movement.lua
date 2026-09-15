
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

local function path_clear_to(start_pos, dir, max_dist)
    local steps = math.max(1, math.floor(max_dist / CROSSHAIR_STEP))
    for step = 1, steps do
        local sample = vector.add(start_pos, vector.multiply(dir, step * CROSSHAIR_STEP))
        local rounded = vector.round(sample)
        rounded.y = S.arena_center.y + 1
        if is_hazard_node(minetest.get_node(rounded).name) then
            return false
        end
    end
    return true
end

minetest.register_globalstep(function(dtime)
    local phase = lobby_system.state.phase
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

                local turret_yaw = pdata.yaw
                if player then
                    turret_yaw = player:get_look_horizontal()
                    local body_pos_now = obj:get_pos()
                    pdata.locked_recognizer = nil
                    if body_pos_now then
                        local aim_dir = minetest.yaw_to_dir(turret_yaw)
                        local shot_origin = { x = body_pos_now.x, y = S.arena_center.y + 1, z = body_pos_now.z }
                        local aim_point = crosshair_target_point(shot_origin, aim_dir)

                        if S.recognizers_enabled and next(battletanks.recognizers) then
                            local max_elevation_tan = math.tan(math.rad(S.recognizer_max_elevation_deg))
                            for _, rec in pairs(battletanks.recognizers) do
                                if rec.body_alive then
                                    local rpos = rec.entities.body:get_pos()
                                    if rpos then
                                        local fx, fz = rpos.x - body_pos_now.x, rpos.z - body_pos_now.z
                                        local t = fx * aim_dir.x + fz * aim_dir.z
                                        if t > 0 then
                                            local closest_x = body_pos_now.x + aim_dir.x * t
                                            local closest_z = body_pos_now.z + aim_dir.z * t
                                            local pdx, pdz = rpos.x - closest_x, rpos.z - closest_z
                                            if math.sqrt(pdx * pdx + pdz * pdz) <= S.recognizer_lock_radius then
                                                local shooter_dist = math.sqrt(fx * fx + fz * fz)
                                                local rise = rpos.y - body_pos_now.y
                                                local min_lock_dist = rise > 0 and (rise / max_elevation_tan) or 0
                                                if shooter_dist >= min_lock_dist
                                                    and path_clear_to(shot_origin, aim_dir, shooter_dist) then
                                                    local tank_in_way = false
                                                    for oname, opdata in pairs(battletanks.players) do
                                                        if opdata.alive and opdata.tank_obj then
                                                            local opos = opdata.tank_obj:get_pos()
                                                            if opos then
                                                                local ofx, ofz = opos.x - body_pos_now.x, opos.z - body_pos_now.z
                                                                local ot = ofx * aim_dir.x + ofz * aim_dir.z
                                                                if ot > 0 and ot < shooter_dist then
                                                                    local ocx = body_pos_now.x + aim_dir.x * ot
                                                                    local ocz = body_pos_now.z + aim_dir.z * ot
                                                                    local otdx, otdz = opos.x - ocx, opos.z - ocz
                                                                    if math.sqrt(otdx * otdx + otdz * otdz) < 1.0 then
                                                                        tank_in_way = true
                                                                        break
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                    if not tank_in_way then
                                                        pdata.locked_recognizer = rec
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        if pdata.locked_recognizer then
                            battletanks.hud.update_crosshair(player, pdata.locked_recognizer.entities.body:get_pos())
                        else
                            battletanks.hud.update_crosshair(player, aim_point)
                        end

                        local now_locked = pdata.locked_recognizer ~= nil
                        pdata.was_locked_on_recognizer = now_locked
                    end
                elseif pdata.bot_turret_yaw then
                    turret_yaw = pdata.bot_turret_yaw
                end
                pdata.turret_yaw = turret_yaw
                if pdata.turret_obj then
                    pdata.turret_obj:set_yaw(turret_yaw)
                end

                if not racing_active then
                    goto continue
                end

                local dir = minetest.yaw_to_dir(pdata.yaw)
                local move_dir = nil
                local is_reverse = false
                if controls.up then
                    move_dir = dir
                elseif controls.down then
                    move_dir = vector.multiply(dir, -1)
                    is_reverse = true
                end

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
                        table.insert(to_eliminate, name)
                        obj:set_velocity({ x = 0, y = 0, z = 0 })
                    elseif is_wall or is_tank_ahead then
                        obj:set_velocity({ x = 0, y = 0, z = 0 })
                    else
                        obj:set_velocity({ x = move_dir.x * speed, y = 0, z = move_dir.z * speed })
                    end
                else
                    obj:set_velocity({ x = 0, y = 0, z = 0 })
                end

                if pdata.turret_obj then
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
                    if pdata.locked_recognizer then
                        battletanks.fire_laser_at_recognizer(name, pos, pdata.locked_recognizer)
                    else
                        battletanks.fire_laser(name, pos, turret_yaw)
                    end
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
                    if pdata.locked_recognizer then
                        battletanks.fire_rocket_at_recognizer(name, pos, pdata.locked_recognizer)
                    else
                        battletanks.fire_rocket(name, pos, turret_yaw)
                    end
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
