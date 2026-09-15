local function face_textures(color)
    return {
        "battletanks_tank_" .. color .. "_top.png",    -- Y+
        "battletanks_tank_" .. color .. "_bottom.png", -- Y-
        "battletanks_tank_" .. color .. "_right.png",  -- X+
        "battletanks_tank_" .. color .. "_left.png",   -- X-
        "battletanks_tank_" .. color .. "_back.png",   -- Z-
        "battletanks_tank_" .. color .. "_front.png",  -- Z+
    }
end

minetest.register_entity("battletanks:tank", {
    initial_properties = {
        visual = "cube",
        visual_size = battletanks.settings.tank_visual_size,
        textures = face_textures("red"),
        collisionbox = { -0.5, -0.4, -0.5, 0.5, 0.4, 0.5 },
        physical = false, -- no engine collision - we do our own node-based checks
        collide_with_objects = false,
        pointable = false,
        static_save = false, -- never persisted; always (re)spawned by the game itself
        glow = 10,
    },

    on_activate = function(self)
        self.object:set_armor_groups({ immortal = 1 })
        self.object:set_acceleration({ x = 0, y = 0, z = 0 })
    end,
})

local function turret_textures(color)
    return {
        "battletanks_turret_" .. color .. "_top.png",    -- Y+
        "battletanks_turret_" .. color .. "_bottom.png", -- Y-
        "battletanks_turret_" .. color .. "_right.png",  -- X+
        "battletanks_turret_" .. color .. "_left.png",   -- X-
        "battletanks_turret_" .. color .. "_front.png",   -- Z-
        "battletanks_turret_" .. color .. "_back.png",  -- Z+
    }
end

minetest.register_entity("battletanks:turret", {
    initial_properties = {
        visual = "cube",
        visual_size = battletanks.settings.turret_visual_size,
        textures = turret_textures("red"),
        physical = false,
        collide_with_objects = false,
        pointable = false,
        static_save = false,
        glow = 10,
    },
})

function battletanks.spawn_turret(parent_obj, color)
    if not parent_obj then return nil end
    local parent_pos = parent_obj:get_pos()
    if not parent_pos then return nil end
    local off = battletanks.settings.turret_attach_offset
    local obj = minetest.add_entity(vector.add(parent_pos, off), "battletanks:turret")
    if not obj then return nil end
    obj:set_properties({ textures = turret_textures(color) })
    return obj
end

function battletanks.despawn_turret(pdata)
    if pdata and pdata.turret_obj then
        pcall(function() pdata.turret_obj:remove() end)
        pdata.turret_obj = nil
    end
end

function battletanks.sync_turret_to_body(pdata)
    if not (pdata and pdata.turret_obj and pdata.tank_obj) then return end
    local body_pos = pdata.tank_obj:get_pos()
    if body_pos then
        pdata.turret_obj:set_pos(vector.add(body_pos, battletanks.settings.turret_attach_offset))
    end
end

function battletanks.spawn_tank(player, pdata, color, pos, yaw)
    local tank_off = battletanks.settings.tank_attach_offset
    local obj = minetest.add_entity({x = pos.x + tank_off.x, y = pos.y  + tank_off.y, z = pos.z  + tank_off.z}, "battletanks:tank")
    if not obj then return nil end
    obj:set_properties({ textures = face_textures(color) })
    obj:set_yaw(yaw)
    local player_off = battletanks.settings.player_attach_offset
    player:set_attach(obj, "", { x = player_off.x, y = player_off.y, z = player_off.z }, { x = 0, y = 0, z = 0 })
    player:set_eye_offset({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 })

    pdata.saved_eye_height = player:get_properties().eye_height
    player:set_properties({ eye_height = battletanks.settings.player_eye_height })

    lobby_system.hide_player_body(player)
    if not battletanks.names_hidden then
        lobby_system.show_nametag(player)
    end

    player:set_look_horizontal(yaw)
    player:set_look_vertical(0)

    pdata.turret_obj = battletanks.spawn_turret(obj, color)

    return obj
end

function battletanks.despawn_tank(player, pdata)
    if player then
        player:set_detach()
        if pdata and pdata.saved_eye_height then
            player:set_properties({ eye_height = pdata.saved_eye_height })
        end
    end
    battletanks.despawn_turret(pdata)
    if pdata and pdata.tank_obj then
        pcall(function() pdata.tank_obj:remove() end)
        pdata.tank_obj = nil
    end
end

function battletanks.spawn_bot_tank(name, color, pos, yaw)
    local obj = minetest.add_entity(pos, "battletanks:tank")
    if not obj then return nil end
    obj:set_properties({
        textures = face_textures(color),
        nametag = battletanks.names_hidden and "" or name,
        nametag_color = "#FFFFFF",
    })
    obj:set_yaw(yaw)
    return obj
end

function battletanks.spawn_crash_effect(pos, color)
    local S = battletanks.settings.crash_effect
    minetest.add_particlespawner({
        amount = S.amount,
        time = S.time,
        minpos = vector.add(pos, { x = -0.3, y = -0.1, z = -0.3 }),
        maxpos = vector.add(pos, { x = 0.3, y = 0.5, z = 0.3 }),
        minvel = { x = -S.speed, y = S.speed * 0.4, z = -S.speed },
        maxvel = { x = S.speed, y = S.speed, z = S.speed },
        minacc = { x = 0, y = -9, z = 0 },
        maxacc = { x = 0, y = -9, z = 0 },
        minexptime = S.min_lifetime,
        maxexptime = S.max_lifetime,
        minsize = S.min_size,
        maxsize = S.max_size,
        texture = "battletanks_wall_" .. color .. "_side.png",
        glow = 12,
        collisiondetection = false,
    })
end

function battletanks.spawn_rocket_blast_effect(pos)
    local S = battletanks.settings.rocket_blast_effect
    minetest.add_particlespawner({
        amount = S.amount,
        time = S.time,
        minpos = vector.add(pos, { x = -0.4, y = -0.1, z = -0.4 }),
        maxpos = vector.add(pos, { x = 0.4, y = 0.6, z = 0.4 }),
        minvel = { x = -S.speed, y = S.speed * 0.5, z = -S.speed },
        maxvel = { x = S.speed, y = S.speed, z = S.speed },
        minacc = { x = 0, y = -9, z = 0 },
        maxacc = { x = 0, y = -9, z = 0 },
        minexptime = S.min_lifetime,
        maxexptime = S.max_lifetime,
        minsize = S.min_size,
        maxsize = S.max_size,
        texture = "battletanks_rocket_projectile.png^[colorize:orange:180",
        glow = 14,
        collisiondetection = false,
    })
end

local function recognizer_body_textures()
    return {
        "battletanks_recognizer_body_top.png",    -- Y+
        "battletanks_recognizer_body_bottom.png", -- Y-
        "battletanks_recognizer_body_right.png",  -- X+
        "battletanks_recognizer_body_left.png",   -- X-
        "battletanks_recognizer_body_back.png",   -- Z-
        "battletanks_recognizer_body_front.png",  -- Z+
    }
end

local RECOGNIZER_LEG_FACES = {
    top = "battletanks_recognizer_leg_top.png",
    bottom = "battletanks_recognizer_leg_bottom.png",
    right = "battletanks_recognizer_leg_right.png",
    left = "battletanks_recognizer_leg_left.png",
    back = "battletanks_recognizer_leg_back.png",
    front = "battletanks_recognizer_leg_front.png",
}

local function recognizer_leg_textures(mirrored)
    local f = RECOGNIZER_LEG_FACES
    if mirrored then
        return { f.top, f.bottom, f.left, f.right, f.front, f.back }
    end
    return { f.top, f.bottom, f.right, f.left, f.back, f.front }
end

minetest.register_entity("battletanks:recognizer_body", {
    initial_properties = {
        visual = "cube",
        visual_size = { x = 2, y = 1, z = 1 }, -- 2 wide, 1 deep, 1 tall
        textures = recognizer_body_textures(),
        physical = false, -- driven by recognizers.lua's own globalstep, not engine physics
        collide_with_objects = false,
        pointable = false,
        static_save = false, -- never persisted - always (re)spawned by the game itself
        glow = 12,
    },
    on_activate = function(self)
        self.object:set_acceleration({ x = 0, y = 0, z = 0 })
    end,
})

minetest.register_entity("battletanks:recognizer_leg", {
    initial_properties = {
        visual = "cube",
        visual_size = { x = 0.25, y = 1, z = 1 },
        textures = recognizer_leg_textures(),
        physical = false,
        collide_with_objects = false,
        pointable = false,
        static_save = false,
        glow = 10,
    },
})

battletanks.recognizer_leg_real_offsets = {
    { x = -0.75, y = -1.0, z = 0 },
    { x = 0.75, y = -1.0, z = 0 },
}

local BODY_X_SCALE = 2
local RECOGNIZER_LEG_OFFSETS = {}
for _, off in ipairs(battletanks.recognizer_leg_real_offsets) do
    table.insert(RECOGNIZER_LEG_OFFSETS, { x = (off.x / BODY_X_SCALE) * 10, y = off.y * 10, z = off.z * 10 })
end

function battletanks.spawn_recognizer_entity(pos)
    local body_pos = { x = pos.x, y = pos.y + 1, z = pos.z }
    local body = minetest.add_entity(body_pos, "battletanks:recognizer_body")
    if not body then return nil end

    local legs = {}
    for i, off in ipairs(RECOGNIZER_LEG_OFFSETS) do
        local leg = minetest.add_entity(body_pos, "battletanks:recognizer_leg")
        if leg then
            leg:set_attach(body, "", off, { x = 0, y = 0, z = 0 })
            if i == 1 then
                leg:set_properties({ textures = recognizer_leg_textures(true) })
            end
        end
        table.insert(legs, leg)
    end

    return { body = body, legs = legs }
end

function battletanks.despawn_recognizer_entity(entities)
    if not entities then return end
    for _, leg in pairs(entities.legs or {}) do
        if leg then pcall(function() leg:remove() end) end
    end
    if entities.body then
        pcall(function() entities.body:remove() end)
    end
end

function battletanks.spawn_recognizer_leg_effect(pos)
    local S = battletanks.settings.recognizer_leg_effect
    minetest.add_particlespawner({
        amount = S.amount,
        time = S.time,
        minpos = vector.add(pos, { x = -0.25, y = -0.35, z = -0.25 }),
        maxpos = vector.add(pos, { x = 0.25, y = 0.35, z = 0.25 }),
        minvel = { x = -S.speed, y = S.speed * 0.4, z = -S.speed },
        maxvel = { x = S.speed, y = S.speed, z = S.speed },
        minacc = { x = 0, y = -9, z = 0 },
        maxacc = { x = 0, y = -9, z = 0 },
        minexptime = S.min_lifetime,
        maxexptime = S.max_lifetime,
        minsize = S.min_size,
        maxsize = S.max_size,
        texture = "battletanks_recognizer_leg_front.png^[colorize:#bfe0ff:90",
        glow = 14,
        collisiondetection = false,
    })
end

function battletanks.spawn_recognizer_body_effect(pos)
    local S = battletanks.settings.recognizer_body_effect
    minetest.add_particlespawner({
        amount = S.amount,
        time = S.time,
        minpos = vector.add(pos, { x = -0.6, y = -0.3, z = -0.4 }),
        maxpos = vector.add(pos, { x = 0.6, y = 0.4, z = 0.4 }),
        minvel = { x = -S.speed, y = S.speed * 0.4, z = -S.speed },
        maxvel = { x = S.speed, y = S.speed, z = S.speed },
        minacc = { x = 0, y = -9, z = 0 },
        maxacc = { x = 0, y = -9, z = 0 },
        minexptime = S.min_lifetime,
        maxexptime = S.max_lifetime,
        minsize = S.min_size,
        maxsize = S.max_size,
        texture = "battletanks_recognizer_body_front.png^[colorize:#dff2ff:70",
        glow = 14,
        collisiondetection = false,
    })
end

function battletanks.spawn_shield_block_effect(pos)
    local S = battletanks.settings.shield_block_effect
    minetest.add_particlespawner({
        amount = S.amount,
        time = S.time,
        minpos = vector.add(pos, { x = -0.3, y = -0.1, z = -0.3 }),
        maxpos = vector.add(pos, { x = 0.3, y = 0.5, z = 0.3 }),
        minvel = { x = -S.speed, y = S.speed * 0.4, z = -S.speed },
        maxvel = { x = S.speed, y = S.speed, z = S.speed },
        minacc = { x = 0, y = -9, z = 0 },
        maxacc = { x = 0, y = -9, z = 0 },
        minexptime = S.min_lifetime,
        maxexptime = S.max_lifetime,
        minsize = S.min_size,
        maxsize = S.max_size,
        texture = "battletanks_powerup_shield.png^[colorize:#90EE90:180",
        glow = 14,
        collisiondetection = false,
    })
end
