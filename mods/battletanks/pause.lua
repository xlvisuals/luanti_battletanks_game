
battletanks.paused = false
battletanks.paused_by = nil

local PAUSE_FLY_PRIVS = { fly = true, fast = true, noclip = true }

local function freeze_all_battlers()
    for _, pdata in pairs(battletanks.players) do
        if pdata.alive and pdata.tank_obj then
            pdata.tank_obj:set_velocity({ x = 0, y = 0, z = 0 })
        end
        if pdata.alive and pdata.turret_obj then
            -- The turret only keeps moving by matching the body's own
            -- velocity every tick (see movement.lua) - since pausing stops
            -- movement.lua's globalstep from running at all, it needs its
            -- own explicit freeze here too, or it'd keep sailing along at
            -- whatever velocity it had the instant before pause.
            pdata.turret_obj:set_velocity({ x = 0, y = 0, z = 0 })
        end
    end
end

local function freeze_all_projectiles()
    for _, p in ipairs(battletanks.projectiles) do
        if p.obj then
            p.velocity_before_pause = p.obj:get_velocity()
            p.obj:set_velocity({ x = 0, y = 0, z = 0 })
        end
    end
end

local function unfreeze_all_projectiles()
    for _, p in ipairs(battletanks.projectiles) do
        if p.obj and p.velocity_before_pause then
            p.obj:set_velocity(p.velocity_before_pause)
            p.velocity_before_pause = nil
        end
    end
end

local function do_pause(name, player, pdata)
    battletanks.paused = true
    battletanks.paused_by = name

    freeze_all_battlers()
    freeze_all_projectiles()

    player:set_detach()
    player:set_physics_override({ speed = 1, jump = 1, gravity = 0 })

    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(PAUSE_FLY_PRIVS) do
        privs[priv] = true
    end
    minetest.set_player_privs(name, privs)

    minetest.chat_send_all("[BattleTanks] " .. name .. " paused the match.")
    -- return true, "[BattleTanks] Match paused - fly/fast/noclip granted. " .. "Press K to actually start flying (the privilege alone doesn't turn it on). " .. "Run /btpause again to resume."
    return true, ""
end

local function do_resume(name, player, pdata)
    battletanks.paused = false
    battletanks.paused_by = nil
    unfreeze_all_projectiles()

    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(PAUSE_FLY_PRIVS) do
        privs[priv] = nil
    end
    minetest.set_player_privs(name, privs)

    if pdata and pdata.alive and pdata.tank_obj then
        local off = battletanks.settings.player_attach_offset
        player:set_attach(pdata.tank_obj, "",
            { x = off.x, y = off.y, z = off.z }, { x = 0, y = 0, z = 0 })
        player:set_physics_override({ speed = 0, jump = 0, gravity = 0 })
    end

    minetest.chat_send_all("[BattleTanks] " .. name .. " resumed the match.")
    return true, "[BattleTanks] Resumed."
end

-- Shared by the /btpause chat command and the keybind watcher below - the
-- actual toggle, independent of how it was triggered. Does not check
-- privileges itself; both callers do that first.
function battletanks.toggle_pause(name)
    local player = minetest.get_player_by_name(name)
    if not player then return false, "Not connected." end

    if battletanks.paused then
        if battletanks.paused_by ~= name then
            return false, "Already paused by " .. tostring(battletanks.paused_by)
                .. " - only they can resume it (re-attaching only makes sense for "
                .. "whoever was actually detached from their own tank)."
        end
        return do_resume(name, player, battletanks.players[name])
    end

    if lobby_system.state.phase ~= "playing" then
        return false, "No match is currently in progress."
    end

    local pdata = battletanks.players[name]
    if not (pdata and pdata.alive) then
        return false, "You need to be an active battler in the current "
            .. "match to use this - it's specifically for pausing "
            .. "mid-battle, not for spectating."
    end

    return do_pause(name, player, pdata)
end

minetest.register_chatcommand("btpause", {
    description = "Admin-only: pause the current match (freezes every "
        .. "racer in place, nobody can be eliminated or collide with "
        .. "anything while paused) and grants yourself fly/fast/noclip so "
        .. "you can move the camera around freely - e.g. to line up a "
        .. "screenshot. Run again to resume. Can also be triggered by "
        .. "pressing the Zoom key (see the note further down this file on "
        .. "binding Zoom to a key of your choice, e.g. Q).",
    func = function(name)
        if not minetest.check_player_privs(name, { lobby_admin = true }) then
            return false, "Needs the lobby_admin priv."
        end
        return battletanks.toggle_pause(name)
    end,
})

-- Keybind support: there's no server-side API to bind an arbitrary
-- keyboard key to a command - a mod can only react to Luanti's existing
-- named control fields (up/down/left/right/jump/aux1/sneak/dig/place/
-- zoom), all of which this game already uses for driving and firing
-- *except* zoom, which is unbound by default and otherwise untouched
-- here. Watching it for an admin's edge-triggered press is the closest
-- thing to a real keybind available.
local was_zoom_pressed = {} -- name -> bool, edge-trigger tracking

minetest.register_globalstep(function(_dtime)
    for name, pdata in pairs(battletanks.players) do
        if not pdata.is_bot and pdata.alive and minetest.check_player_privs(name, { lobby_admin = true }) then
            local player = minetest.get_player_by_name(name)
            if player then
                local controls = player:get_player_control()
                if controls.zoom and not was_zoom_pressed[name] then
                    battletanks.toggle_pause(name)
                end
                was_zoom_pressed[name] = controls.zoom
            end
        end
    end
end)

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    was_zoom_pressed[name] = nil
    if battletanks.paused and battletanks.paused_by == name then
        battletanks.paused = false
        battletanks.paused_by = nil
        minetest.chat_send_all("[BattleTanks] " .. name
            .. " disconnected while paused - match resumed automatically.")
    end
end)
