
local S = battletanks.settings

battletanks.recognizers = {}


local EDGE_MARGIN = 2

local function clamp_to_playfield(x, z)
    local b = battletanks.arena_bounds()
    local minx, maxx = b.min_x + EDGE_MARGIN, b.max_x - EDGE_MARGIN
    local minz, maxz = b.min_z + EDGE_MARGIN, b.max_z - EDGE_MARGIN
    if x < minx then x = minx elseif x > maxx then x = maxx end
    if z < minz then z = minz elseif z > maxz then z = maxz end
    return x, z
end

function battletanks.recognizer_spawn_pos_for(spawn_pos)
    local c = S.arena_center
    local dx, dz = spawn_pos.x - c.x, spawn_pos.z - c.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local nx, nz = 0, 0
    if dist > 0.0001 then
        nx, nz = dx / dist, dz / dist
    end

    local x = spawn_pos.x + nx * S.recognizer_lateral_offset
    local z = spawn_pos.z + nz * S.recognizer_lateral_offset
    x, z = clamp_to_playfield(x, z)

    return { x = x, y = spawn_pos.y + S.recognizer_height_offset, z = z }
end


function battletanks.despawn_recognizer_for(name)
    local rec = battletanks.recognizers[name]
    if not rec then return end
    battletanks.despawn_recognizer_entity(rec.entities)
    battletanks.recognizers[name] = nil
end

local function schedule_recognizer_respawn(name, spawn_pos, generation)
    minetest.after(S.recognizer_respawn_time, function()
        if not S.recognizers_enabled then return end
        if battletanks.match_generation ~= generation then return end
        if lobby_system.state.phase ~= "playing" then return end
        local pdata = battletanks.players[name]
        if not (pdata and pdata.alive and pdata.racing) then return end
        if battletanks.recognizers[name] then return end -- already has one somehow

        battletanks.spawn_recognizer_for(name, spawn_pos, generation)
    end)
end

function battletanks.spawn_recognizer_for(name, spawn_pos, generation)
    if not S.recognizers_enabled then return end
    if battletanks.recognizers[name] then return end -- one per tank, already has one

    local pos = battletanks.recognizer_spawn_pos_for(spawn_pos)
    local entities = battletanks.spawn_recognizer_entity(pos)
    if not entities or not entities.body then return end

    local pdata = battletanks.players[name]
    local face_pos = (pdata and pdata.tank_obj and pdata.tank_obj:get_pos()) or spawn_pos
    local fx, fz = face_pos.x - pos.x, face_pos.z - pos.z
    if fx ~= 0 or fz ~= 0 then
        entities.body:set_yaw(minetest.dir_to_yaw({ x = fx, y = 0, z = fz }))
    end

    battletanks.recognizers[name] = {
        owner_name = name,
        entities = entities,
        state = "cruise",
        legs_alive = { true, true },
        body_alive = true,
        cruise_y = pos.y + 1,
        spawn_pos = spawn_pos,
        target = { x = pos.x, z = pos.z },
        retarget_timer = 0,
        match_generation = generation,
    }
end

function battletanks.on_tank_eliminated_for_recognizer(name)
    battletanks.despawn_recognizer_for(name)
end

function battletanks.spawn_recognizer_if_enabled(name, spawn_pos)
    if not S.recognizers_enabled then return end
    battletanks.spawn_recognizer_for(name, spawn_pos, battletanks.match_generation)
end

function battletanks.clear_all_recognizers()
    for name, _ in pairs(battletanks.recognizers) do
        battletanks.despawn_recognizer_for(name)
    end
end


local function leg_world_pos(rec, leg_index)
    local body = rec.entities.body
    local body_pos = body:get_pos()
    if not body_pos then return nil end
    local yaw = body:get_yaw() or 0
    local off = battletanks.recognizer_leg_real_offsets[leg_index]
    local cos_y, sin_y = math.cos(yaw), math.sin(yaw)
    return {
        x = body_pos.x + off.x * cos_y - off.z * sin_y,
        y = body_pos.y + off.y,
        z = body_pos.z + off.x * sin_y + off.z * cos_y,
    }
end

function battletanks.register_recognizer_hit(rec, shooter_name)
    if not rec or not rec.body_alive then return false end

    for i = 1, 2 do
        if rec.legs_alive[i] then
            rec.legs_alive[i] = false
            local leg = rec.entities.legs[i]
            if leg then
                local leg_pos = leg_world_pos(rec, i)
                if leg_pos then battletanks.spawn_recognizer_leg_effect(leg_pos) end
                pcall(function() leg:remove() end)
            end
            rec.entities.legs[i] = nil
            minetest.chat_send_all("[BattleTanks] " .. shooter_name
                .. " shot a leg off a Recognizer!")
            return false
        end
    end

    rec.body_alive = false
    local body_pos = rec.entities.body:get_pos()
    if body_pos then battletanks.spawn_recognizer_body_effect(body_pos) end
    local spawn_pos, generation = rec.spawn_pos, rec.match_generation
    local owner_name = rec.owner_name
    battletanks.despawn_recognizer_for(owner_name)

    local shooter_pdata = battletanks.players[shooter_name]
    if shooter_pdata and shooter_pdata.alive then
        lobby_system.add_score(shooter_name, S.recognizer_points)
        shooter_pdata.battle_score = shooter_pdata.battle_score + S.recognizer_points
        lobby_system.hud.update_all_scoreboards()
        battletanks.hud.update_battle_table()
    end
    minetest.chat_send_all("[BattleTanks] " .. shooter_name .. " derezzed a Recognizer! (+" .. S.recognizer_points .. ")")

    schedule_recognizer_respawn(owner_name, spawn_pos, generation)
    return true
end


local function horizontal_distance(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

local function move_recognizer(name, rec, dtime)
    local pdata = battletanks.players[name]
    if not (pdata and pdata.alive and pdata.tank_obj) then return end
    local tank_pos = pdata.tank_obj:get_pos()
    if not tank_pos then return end

    local body = rec.entities.body
    local body_pos = body:get_pos()
    if not body_pos then return end

    rec.retarget_timer = rec.retarget_timer - dtime
    if rec.retarget_timer <= 0 then
        rec.target.x, rec.target.z = tank_pos.x, tank_pos.z
        rec.retarget_timer = S.recognizer_retarget_interval
    end

    local cruise_speed = S.base_speed * S.recognizer_speed_ratio
    local vertical_speed = cruise_speed * S.recognizer_vertical_speed_multiplier

    local hdx, hdz = rec.target.x - body_pos.x, rec.target.z - body_pos.z
    local hdist = math.sqrt(hdx * hdx + hdz * hdz)
    local vel_x, vel_z = 0, 0
    if hdist > 0.05 then
        vel_x = (hdx / hdist) * cruise_speed
        vel_z = (hdz / hdist) * cruise_speed
        body:set_yaw(minetest.dir_to_yaw({ x = hdx, y = 0, z = hdz }))
    end

    local vel_y = 0
    local dist_to_tank = horizontal_distance(body_pos.x, body_pos.z, tank_pos.x, tank_pos.z)

    if rec.state == "cruise" then
        if dist_to_tank <= S.recognizer_stomp_radius then
            rec.state = "stomp"
        end
    elseif rec.state == "stomp" then
        if dist_to_tank > S.recognizer_stomp_radius then
            rec.state = "recover"
        else
            vel_y = -vertical_speed
            if (body_pos.y - tank_pos.y) <= S.recognizer_stomp_hit_height then
                battletanks.eliminate(name, name .. " was stomped by a Recognizer!")
                return
            end
        end
    elseif rec.state == "recover" then
        vel_y = vertical_speed
        if body_pos.y >= rec.cruise_y then
            body:set_pos({ x = body_pos.x, y = rec.cruise_y, z = body_pos.z })
            rec.state = "cruise"
        end
    end

    body:set_velocity({ x = vel_x, y = vel_y, z = vel_z })
end

minetest.register_globalstep(function(dtime)
    if battletanks.paused then return end
    if lobby_system.state.phase ~= "playing" then
        for _, rec in pairs(battletanks.recognizers) do
            if rec.entities.body then
                rec.entities.body:set_velocity({ x = 0, y = 0, z = 0 })
            end
        end
        return
    end
    if not S.recognizers_enabled then return end

    for name, rec in pairs(battletanks.recognizers) do
        move_recognizer(name, rec, dtime)
    end
end)
