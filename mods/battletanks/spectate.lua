
local last_aux1 = {} -- name -> bool, for edge-detecting the tank key

local function alive_names_sorted()
    local list = {}
    for name, pdata in pairs(battletanks.players) do
        if pdata.alive then table.insert(list, name) end
    end
    table.sort(list)
    return list
end

function battletanks.enter_spectate(player, pdata)
    pdata.mode = "spectating"
    pdata.spec_index = 1
    player:set_physics_override({ speed = 1, jump = 0, gravity = 0 })
    lobby_system.hide_player_body(player)
    lobby_system.hide_nametag(player)
    battletanks.hud.remove_boost_bar(player)
    lobby_system.hud.set_status(player, "DEREZZED - spectating (press E to switch)")
end

local function spectate_target(pdata)
    local names = alive_names_sorted()
    if #names == 0 then return nil end
    pdata.spec_index = ((pdata.spec_index - 1) % #names) + 1
    return names[pdata.spec_index]
end

minetest.register_globalstep(function(dtime)
    if lobby_system.state.phase ~= "playing" then return end

    for name, pdata in pairs(battletanks.players) do
        if pdata.mode == "spectating" then
            local player = minetest.get_player_by_name(name)
            if player and player:is_player() then
                local controls = player:get_player_control()
                if controls.aux1 and not last_aux1[name] then
                    pdata.spec_index = (pdata.spec_index or 0) + 1
                end
                last_aux1[name] = controls.aux1

                local target_name = spectate_target(pdata)
                if target_name then
                    local target = minetest.get_player_by_name(target_name)
                    local tdata = battletanks.players[target_name]
                    if target and tdata and tdata.tank_obj and tdata.tank_obj:get_pos() then
                        local dir = minetest.yaw_to_dir(tdata.yaw)
                        local tpos = tdata.tank_obj:get_pos()
                        local behind = vector.subtract(tpos, vector.multiply(dir, 4))
                        behind.y = tpos.y + 2
                        player:set_pos(behind)
                        player:set_look_horizontal(tdata.yaw)
                        lobby_system.hud.set_status(player,
                            "DEREZZED - watching " .. target_name .. " (press E to switch)")
                    end
                else
                    lobby_system.hud.set_status(player, "DEREZZED - no players left to watch")
                end
            end
        end
    end
end)
