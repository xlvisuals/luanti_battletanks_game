
local observers = {} -- name -> { attached_to = nil | <racer name> }
local last_trigger = {} -- name -> bool, edge-detecting the cycle key
local status_clear_jobs = {} -- name -> job, so switching targets quickly doesn't leave several stacked clear timers

local STATUS_TIMEOUT = 3

local function flash_status(player, text)
    local name = player:get_player_name()
    if status_clear_jobs[name] then
        status_clear_jobs[name]:cancel()
        status_clear_jobs[name] = nil
    end
    if battletanks.messages_hidden then return end
    lobby_system.hud.set_status(player, text)
    status_clear_jobs[name] = minetest.after(STATUS_TIMEOUT, function()
        status_clear_jobs[name] = nil
        lobby_system.hud.clear_status(player)
    end)
end

local OBSERVE_ATTACH_OFFSET = { x = 0, y = 10, z = 0 }

local function is_observer(name)
    return not battletanks.players[name] and not battletanks.is_build_mode_on(name)
end

local function racer_names_sorted()
    local list = {}
    for name, pdata in pairs(battletanks.players) do
        if pdata.alive and pdata.tank_obj then
            table.insert(list, name)
        end
    end
    table.sort(list)
    return list
end

local function attach_to(player, obs, racer_name)
    local pdata = battletanks.players[racer_name]
    if not (pdata and pdata.alive and pdata.tank_obj) then return false end
    player:set_attach(pdata.tank_obj, "", OBSERVE_ATTACH_OFFSET, { x = 0, y = 0, z = 0 })
    obs.attached_to = racer_name
    flash_status(player, "Observing " .. racer_name .. " - click to switch, look around freely")
    return true
end

local function detach_to_freelook(player, obs)
    player:set_detach()
    obs.attached_to = nil
    player:set_physics_override({
        speed = 1, jump = 1, gravity = 0, sneak = false, sneak_glitch = false,
    })
    flash_status(player, "Free-look - click to observe a racer")
end

local function current_cycle_index(attached_to, names)
    if not attached_to then return 0 end
    for i, n in ipairs(names) do
        if n == attached_to then return i end
    end
    return 0 -- target no longer valid (eliminated/disconnected) - treat as free-look
end

minetest.register_globalstep(function(_dtime)
    local phase = lobby_system.state.phase
    if phase ~= "playing" and phase ~= "countdown" then return end

    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        if is_observer(name) then
            local obs = observers[name]
            if not obs then
                obs = { attached_to = nil }
                observers[name] = obs
            end

            if obs.attached_to then
                local tdata = battletanks.players[obs.attached_to]
                if not (tdata and tdata.alive and tdata.tank_obj) then
                    detach_to_freelook(player, obs)
                end
            end

            local controls = player:get_player_control()
            local pressed = controls.dig
            if pressed and not last_trigger[name] then
                local names = racer_names_sorted()
                local total = #names + 1 -- +1 for the free-look stop
                local next_index = (current_cycle_index(obs.attached_to, names) + 1) % total
                if next_index == 0 then
                    detach_to_freelook(player, obs)
                elseif not attach_to(player, obs, names[next_index]) then
                    detach_to_freelook(player, obs) -- shouldn't normally happen, but stay safe
                end
            end
            last_trigger[name] = pressed
        end
    end
end)

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    observers[name] = nil
    last_trigger[name] = nil
    if status_clear_jobs[name] then
        status_clear_jobs[name]:cancel()
        status_clear_jobs[name] = nil
    end
end)
