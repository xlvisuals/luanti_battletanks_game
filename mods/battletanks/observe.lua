-- Lets a non-racing, idle/observing player (see lobby_system's idle
-- state - granted free-fly movement there) attach their camera to a live
-- racer's tank and cycle through everyone currently racing, plus their
-- own free-fly view, by pressing left-click (dig).
--
-- This uses a real engine attachment (set_attach) for position tracking,
-- not a per-tick set_pos() - the same lesson learned the hard way earlier
-- in this project with the turret (see entity.lua's spawn_turret
-- comment): an explicit position write every tick gets sent to clients as
-- a teleport each time, fighting normal interpolation. Unlike the turret,
-- though, there's no need for any of that fix's complexity here, because
-- attachment is exactly the right tool for this job: we never call
-- set_look_horizontal/vertical on the observer at all, so their own look
-- direction stays entirely under their own control - free-look, exactly
-- as asked for, comes for free simply by not touching it.

local observers = {} -- name -> { attached_to = nil | <racer name> }
local last_trigger = {} -- name -> bool, edge-detecting the cycle key
local status_clear_jobs = {} -- name -> job, so switching targets quickly doesn't leave several stacked clear timers

-- How long the "Observing X.../Free-look..." hint stays on screen -
-- purely a transient confirmation of what just happened, not something
-- that needs to sit there permanently.
local STATUS_TIMEOUT = 3

-- Shows a temporary status hint, respecting the same "/bt hide messages"
-- toggle the big flash notifications use (see ui_toggle.lua) - this isn't
-- routed through flash_all itself since that broadcasts to everyone, and
-- this is specific to the one observer who just switched targets.
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

-- In the same "x10" units set_attach expects (see entity.lua's comment on
-- this) - real-world offset is this divided by 10: 1 node directly above
-- the tank's own center, high enough to clear the hull/turret.
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
    -- Same physics lobby_system's enter_idle_state grants an idle
    -- observer - set_detach() leaves them exactly where they were (e.g.
    -- wherever they were just watching from), which is a perfectly
    -- reasonable place to start free-flying from, so there's no need to
    -- teleport anywhere.
    player:set_physics_override({
        speed = 1, jump = 1, gravity = 0, sneak = false, sneak_glitch = false,
    })
    flash_status(player, "Free-look - click to observe a racer")
end

-- Index 0 means "free-look" (not attached to anyone); 1..#names maps onto
-- that sorted list. Kept as a plain number cycle rather than putting nil
-- into a table, since a literal nil as the first element of an array
-- breaks ipairs() from ever seeing anything after it.
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

            -- If whoever we're watching died or disconnected mid-
            -- observation, fall back to free-look rather than staying
            -- attached to a tank that's no longer there.
            if obs.attached_to then
                local tdata = battletanks.players[obs.attached_to]
                if not (tdata and tdata.alive and tdata.tank_obj) then
                    detach_to_freelook(player, obs)
                end
            end

            local controls = player:get_player_control()
            -- local pressed = controls.jump or controls.dig
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
