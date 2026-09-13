
battletanks.names_hidden = false
battletanks.boost_hidden = false
battletanks.messages_hidden = false

local function set_boost_hidden(hidden)
    battletanks.boost_hidden = hidden
    for name, pdata in pairs(battletanks.players) do
        if pdata.alive and not pdata.is_bot then
            local player = minetest.get_player_by_name(name)
            if player then
                battletanks.hud.set_boost_visible(player, not hidden)
            end
        end
    end
end

local function set_names_hidden(hidden)
    battletanks.names_hidden = hidden
    for name, pdata in pairs(battletanks.players) do
        if pdata.alive then
            if pdata.is_bot then
                if pdata.tank_obj then
                    pdata.tank_obj:set_properties({ nametag = hidden and "" or name })
                end
            else
                local player = minetest.get_player_by_name(name)
                if player then
                    if hidden then
                        lobby_system.hide_nametag(player)
                    else
                        lobby_system.show_nametag(player)
                    end
                end
            end
        end
    end
end

-- Every big on-screen flash notification (lobby_system.hud.flash_all) -
-- eliminations, "GO!", win announcements, all of it - handy to turn off
-- right before lining up a screenshot, which any of those would
-- otherwise cover. The matching chat messages and sounds are untouched,
-- so everything is still tracked/audible, just not covering the screen.
local function set_messages_hidden(hidden)
    battletanks.messages_hidden = hidden
    lobby_system.hide_flash_messages = hidden
end

local UI_ELEMENTS = {
    score = function(hidden)
        lobby_system.hud.set_scoreboard_hidden(hidden)
        battletanks.hud.set_battle_table_admin_hidden(hidden)
    end,
    battle = function(hidden) lobby_system.hud.set_match_counter_hidden(hidden) end,
    names = set_names_hidden,
    boost = set_boost_hidden,
    messages = set_messages_hidden,
}

function battletanks.handle_ui_command(name, param)
    local verb, element = param:match("^(%a+)%s+(%a+)$")
    if not (verb == "show" or verb == "hide") then
        return false
    end
    local is_all = element == "all"
    if not (is_all or UI_ELEMENTS[element]) then
        return false
    end

    if not minetest.check_player_privs(name, { lobby_admin = true }) then
        minetest.chat_send_player(name, "[BattleTanks] Needs the lobby_admin priv.")
        return true
    end

    local hidden = verb == "hide"
    if is_all then
        for _, apply in pairs(UI_ELEMENTS) do
            apply(hidden)
        end
        minetest.chat_send_player(name, "[BattleTanks] All UI elements "
            .. (hidden and "hidden." or "shown."))
    else
        UI_ELEMENTS[element](hidden)
        minetest.chat_send_player(name, "[BattleTanks] " .. element .. " "
            .. (hidden and "hidden." or "shown."))
    end
    return true
end
