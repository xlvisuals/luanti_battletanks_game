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
        -- Square footprint (x == z), not stretched along the forward
        -- axis like the original lightcycle body - a tank needs to read
        -- its own heading at a glance for turning to feel precise, and an
        -- elongated shape sweeps a much larger, harder-to-judge arc as it
        -- rotates than a square one does.
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

-- The turret: a separate entity that shadows the tank body's position
-- (see spawn_turret/movement.lua) so its yaw can follow the player's
-- actual look direction independently of the body's own cardinal-locked
-- yaw.
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

-- Spawns a turret entity positioned at `parent_obj`'s current position
-- (plus turret_attach_offset) and returns it. This deliberately does NOT
-- use object:set_attach(): attached child objects have their position and
-- rotation setters silently ignored by the engine ("get_pos and
-- get_rotation will always return the parent's values and changes via
-- their setter counterparts are ignored" - Luanti API docs), which would
-- make it impossible to ever aim the turret independently of the body.
-- Instead movement.lua re-positions and re-yaws this object by hand every
-- tick, in lockstep with the tank body - a free-standing entity that
-- happens to follow another one, not a true attachment.
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

-- One-off correction, not a per-tick thing: hard-snaps the turret entity
-- back to "body position + offset". Needed anywhere the body's own
-- position jumps outside of normal velocity integration (currently just
-- the 90-degree-turn grid-snap in movement.lua) - the turret otherwise
-- tracks the body every tick purely by matching its velocity (see
-- movement.lua), which is what keeps it moving smoothly instead of
-- visibly stepping; calling set_pos() every single tick as well as
-- matching velocity is what caused that stepping in the first place, so
-- this is deliberately only called at the rare moments it's actually
-- needed.
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

-- A rocket's own impact burst - unlike spawn_crash_effect above, this
-- isn't tied to any particular racer's color, since a rocket can just as
-- easily detonate against a bare wall with nobody nearby as it can against
-- a tank. Always shown on any rocket detonation (see explode_rocket in
-- projectiles.lua), so a wall hit still visibly reads as an explosion
-- instead of the rocket just silently vanishing.
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
