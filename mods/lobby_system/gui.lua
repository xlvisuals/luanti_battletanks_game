
lobby_system.gui = {}

local FORMNAME = "lobby_system:panel"

local function lobby_names_sorted()
    local list = {}
    for n, _ in pairs(lobby_system.state.lobby) do table.insert(list, n) end
    table.sort(list)
    return list
end

function lobby_system.gui.build(name)
    local state = lobby_system.state
    local S = lobby_system.settings
    local g = state.game
    local title = (g and g.title) or "Lobby"
    local in_lobby = state.lobby[name] and true or false
    local lobby_names = lobby_names_sorted()
    local lobby_list = table.concat(lobby_names, ", ")
    if lobby_list == "" then lobby_list = "(nobody yet)" end

    local phase_label
    if state.phase == "lobby" then
        phase_label = in_lobby and "Waiting for match" or "Waiting in lobby"
    else
        phase_label = ({
            countdown = "Starting...",
            playing = "Match in progress",
            ended = "Match just ended",
        })[state.phase] or state.phase
    end

    local fs = {
        "formspec_version[4]",
        "size[8.5,12.1]",
        "bgcolor[#000000AD]", -- Background. Default is bgcolor[#000000AA]
        "style_type[label;font_size=*1.3]",
        "label[0.4,0.5;" .. minetest.formspec_escape(title) .. "]",
        "style_type[label;font_size=*1]",
        "label[0.4,1.1;Your score: " .. lobby_system.get_score(name) .. "]",
        "label[0.4,1.7;" .. minetest.formspec_escape(phase_label) .. "]",
        "label[4.55,1.7;Joined (" .. #lobby_names .. "/" .. S.max_players .. "): "
            .. minetest.formspec_escape(lobby_list) .. "]",
    }

    if g and g.show_help then
        table.insert(fs, "button[6.05,0.3;2,0.6;ls_help;Help]")
    end

    if state.phase == "lobby" then
        if in_lobby then
            table.insert(fs, "button[0.4,2.9;3.85,0.8;ls_leave;Leave Game]")
        else
            table.insert(fs, "button[0.4,2.9;3.85,0.8;ls_join;Join Game]")
        end
        table.insert(fs, "button[4.4,2.9;3.7,0.8;ls_start;Start Battle]")
    elseif state.phase == "countdown" then
        if state.countdown_left > S.late_join_cutoff then
            table.insert(fs, "label[0.4,3.1;Starting in " .. state.countdown_left
                .. "s - you can still jump in!]")
            table.insert(fs, "button[0.4,3.7;7.7,0.8;ls_join;Join Battle]")
        else
            table.insert(fs, "label[0.4,3.1;Too late to join this match - starting now!]")
        end
    else
        table.insert(fs, "label[0.4,3.1;(join/start are only available between matches)]")
    end

    if g and g.extra_formspec then
        local extra = g.extra_formspec(name)
        if extra then table.insert(fs, extra) end
    end

    return table.concat(fs, "")
end

function lobby_system.gui.show(name)
    if lobby_system.before_show_fn then lobby_system.before_show_fn(name) end
    minetest.show_formspec(name, FORMNAME, lobby_system.gui.build(name))
end

function lobby_system.gui.close(name)
    minetest.close_formspec(name, FORMNAME)
end

function lobby_system.gui.on_match_start(racer_names)
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        if racer_names[pname] then
            minetest.close_formspec(pname, FORMNAME)
        else
            lobby_system.gui.show(pname)
        end
    end
end

function lobby_system.gui.refresh_non_players()
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        if not lobby_system.state.players[pname] then
            lobby_system.gui.show(pname)
        end
    end
end

function lobby_system.gui.refresh_all()
    for _, player in ipairs(minetest.get_connected_players()) do
        lobby_system.gui.show(player:get_player_name())
    end
end


local CONFIRM_FORMNAME = "lobby_system:confirm_start"

function lobby_system.gui.show_start_confirm(name, not_joined_count)
    local plural = not_joined_count == 1 and "" or "s"
    local verb = not_joined_count == 1 and "hasn't" or "haven't"
    local fs = {
        "formspec_version[4]",
        "size[7.5,3.6]",
        "label[0.4,0.5;" .. not_joined_count .. " other connected player" .. plural
            .. " " .. verb .. " joined yet.]",
        "label[0.4,1.1;Start the match anyway?]",
        "button[0.4,2.2;3.2,0.8;ls_confirm_yes;Start Anyway]",
        "button[3.9,2.2;3.2,0.8;ls_confirm_no;Cancel]",
    }
    minetest.show_formspec(name, CONFIRM_FORMNAME, table.concat(fs, ""))
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= CONFIRM_FORMNAME then return end
    local name = player:get_player_name()

    if fields.ls_confirm_yes then
        local ok, err = lobby_system.lobby.start(name)
        if not ok then
            minetest.chat_send_player(name, err)
            lobby_system.gui.show(name)
        end
    elseif fields.ls_confirm_no or fields.quit then
        lobby_system.gui.show(name)
    end

    return true
end)

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= FORMNAME then return end
    local name = player:get_player_name()
    local g = lobby_system.state.game

    if fields.ls_join then
        lobby_system.lobby.join(name)
        if lobby_system.state.players[name] then
            minetest.close_formspec(name, FORMNAME)
        else
            lobby_system.gui.show(name)
        end
    elseif fields.ls_leave then
        lobby_system.lobby.leave(name)
        lobby_system.gui.show(name)
    elseif fields.ls_start then
        local ok, err = lobby_system.lobby.start_with_confirmation(name)
        if not ok then
            minetest.chat_send_player(name, err)
            lobby_system.gui.show(name)
        end
    elseif fields.ls_help then
        if g and g.show_help then g.show_help(name) end
    elseif g and g.on_extra_fields then
        if g.on_extra_fields(name, fields) then
            lobby_system.gui.show(name)
        end
    end

    return true
end)
