
local S = battletanks.settings

battletanks.projectiles = {} -- { { obj=, shooter_name=, spawn_us=, kind="laser"|"rocket", last_pos=, trail_spawner= (rocket only) }, ... }

local HIT_RADIUS = 0.6

local function try_shield_block(name, hit_pos)
    local pdata = battletanks.players[name]
    if not pdata or not pdata.shield or pdata.shield <= 0 then return false end
    pdata.shield = pdata.shield - 1
    battletanks.hud.update_shield(minetest.get_player_by_name(name), pdata.shield)
    battletanks.sounds.play_shield_break(hit_pos)
    battletanks.spawn_shield_block_effect(hit_pos)
    minetest.chat_send_all("[BattleTanks] " .. name .. "'s shield absorbed a hit! (" .. pdata.shield .. " left)")
    return true
end

minetest.register_entity("battletanks:laser_bolt", {
    initial_properties = {
        visual = "cube",
        visual_size = battletanks.settings.laser_visual_size,
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
        visual_size = battletanks.settings.rocket_visual_size,
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

function battletanks.fire_laser(name, pos, yaw)
    local dir = minetest.yaw_to_dir(yaw)
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

function battletanks.fire_rocket(name, pos, yaw)
    local dir = minetest.yaw_to_dir(yaw)
    local spawn_pos = vector.add(pos, vector.multiply(dir, 1.2))
    spawn_pos.y = pos.y

    local obj = minetest.add_entity(spawn_pos, "battletanks:rocket")
    if not obj then return end
    obj:set_yaw(yaw)
    local speed = S.base_speed * S.rocket_speed_multiplier
    obj:set_velocity({ x = dir.x * speed, y = 0, z = dir.z * speed })

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

local BLAST_RADIUS = 1

local function explode_rocket(center, shooter_name)
    local cx, cz = center.x, center.z
    local y = S.arena_center.y + 1
    battletanks.sounds.play_rocket_explosion({ x = cx, y = y, z = cz })
    battletanks.spawn_rocket_blast_effect({ x = cx, y = y, z = cz })

    for dx = -BLAST_RADIUS, BLAST_RADIUS do
        for dz = -BLAST_RADIUS, BLAST_RADIUS do
            local p = { x = cx + dx, y = y, z = cz + dz }

            for rname, pdata in pairs(battletanks.players) do
                if pdata.alive and pdata.tank_obj and not battletanks.is_admin_invincible(rname) then
                    local cpos = pdata.tank_obj:get_pos()
                    if cpos then
                        local rp = vector.round(cpos)
                        if rp.x == p.x and rp.z == p.z then
                            if not try_shield_block(rname, p) then
                                if rname == shooter_name then
                                    battletanks.eliminate(rname, rname
                                        .. " was derezzed by their own rocket blast!")
                                else
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
end

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

local SWEEP_STEP = 0.25

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
            if pdata.alive and pdata.tank_obj and (rname ~= p.shooter_name or allow_self)
                and not battletanks.is_admin_invincible(rname) then
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
                    local hit_pdata = battletanks.players[hit_name]
                    local hit_pos = hit_pdata and hit_pdata.tank_obj and hit_pdata.tank_obj:get_pos()
                    local rounded_hit_pos = vector.round(hit_pos or hit.pos)
                    if not try_shield_block(hit_name, rounded_hit_pos) then
                        explode_rocket(rounded_hit_pos, p.shooter_name)
                    end
                else
                    if not try_shield_block(hit_name, hit.pos) then
                        if hit_name == p.shooter_name then
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
            if p.trail_spawner then
                pcall(function() minetest.delete_particlespawner(p.trail_spawner) end)
            end
            table.remove(battletanks.projectiles, i)
        end
    end
end)
