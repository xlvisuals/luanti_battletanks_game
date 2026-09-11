
lobby_system.lobby = {}
local S = lobby_system.settings
local state = lobby_system.state

local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function game()
    return state.game
end

local function idle_pos_and_yaw()
    local g = game()
    if g and g.get_idle_pos then
        local pos, yaw = g.get_idle_pos()
        if pos then return pos, yaw or 0 end
    end
    return S.default_idle_pos, S.default_idle_yaw
end


lobby_system.messages = {
    joined_lobby = "%s joined the lobby",
    left_lobby = "%s left the lobby",
    joined_game = "%s joined the game",
    left_game = "%s left the game",
}

local function format_message(key, name, info)
    local m = lobby_system.messages[key]
    if type(m) == "function" then return m(name, info) end
    return string.format(m, name)
end

function lobby_system.set_joined_lobby_text(text_or_fn) lobby_system.messages.joined_lobby = text_or_fn end
function lobby_system.set_left_lobby_text(text_or_fn) lobby_system.messages.left_lobby = text_or_fn end
function lobby_system.set_joined_game_text(text_or_fn) lobby_system.messages.joined_game = text_or_fn end
function lobby_system.set_left_game_text(text_or_fn) lobby_system.messages.left_game = text_or_fn end


function lobby_system.set_countdown_seconds(n) S.countdown_seconds = n end
function lobby_system.set_max_players(n) S.max_players = n end
function lobby_system.set_min_players(n) S.min_players = n end
function lobby_system.set_score_to_win_game(n) S.score_to_win_game = n end
function lobby_system.set_matches_per_game(n) S.matches_per_game = n end
function lobby_system.set_reset_score_on_join(bool) S.reset_score_on_join = bool end
function lobby_system.set_new_game_on_second_player(bool) S.new_game_on_second_player = bool end

function lobby_system.register_game(def)
    assert(def and def.on_match_start, "lobby_system.register_game needs at least on_match_start")
    state.game = def
    if def.countdown_seconds then S.countdown_seconds = def.countdown_seconds end
    if def.late_join_cutoff then S.late_join_cutoff = def.late_join_cutoff end
    if def.max_players then S.max_players = def.max_players end
    if def.min_players then S.min_players = def.min_players end
    if def.score_to_win_game then S.score_to_win_game = def.score_to_win_game end
    if def.matches_per_game then S.matches_per_game = def.matches_per_game end

    minetest.register_chatcommand(def.command or "lobby", {
        params = "[join|leave|start|score|help|menu]",
        description = (def.title or "Lobby") .. " commands (run with no arguments to open the panel)",
        func = function(name, param)
            param = (param or ""):match("^%s*(.-)%s*$")
            if param == "" or param == "menu" then
                lobby_system.gui.show(name)
            elseif param == "join" then
                lobby_system.lobby.join(name)
            elseif param == "leave" then
                lobby_system.lobby.leave(name)
            elseif param == "start" then
                local ok, err = lobby_system.lobby.start_with_confirmation(name)
                if not ok then minetest.chat_send_player(name, err) end
            elseif param == "score" or param == "scores" then
                minetest.chat_send_player(name, "Your score: " .. lobby_system.get_score(name))
            elseif param == "help" then
                local g = game()
                if g and g.show_help then
                    g.show_help(name)
                else
                    minetest.chat_send_player(name, "No help available for this game.")
                end
            else
                local g = game()
                local handled = g and g.on_extra_command and g.on_extra_command(name, param)
                if not handled then
                    minetest.chat_send_player(name,
                        "Usage: /" .. (def.command or "lobby")
                        .. " (opens the panel) | join | leave | start | score | help")
                end
            end
            return true
        end,
    })
end


function lobby_system.lobby.join(name)
    local g = game()
    if not g then return end

    if state.phase == "countdown" then
        if state.countdown_left <= S.late_join_cutoff then
            minetest.chat_send_player(name, "Too late to join this match - it's about to start. "
                .. "Try again once it's back to the lobby.")
            return
        end
        if state.next_index > S.max_players then
            minetest.chat_send_player(name, "This match is full (" .. S.max_players .. " max).")
            return
        end
        lobby_system.lobby.start_one_player(name, state.next_index)
        state.next_index = state.next_index + 1
        local msg = format_message("joined_game", name, { index = state.next_index - 1 })
        minetest.chat_send_all(msg)
        lobby_system.hud.flash_all(msg, 2)
        lobby_system.sounds.play_joined()
        lobby_system.hud.update_all_scoreboards()
        return
    end

    if state.phase ~= "lobby" then
        minetest.chat_send_player(name, "A match is already in progress, wait for it to finish.")
        return
    end
    if state.lobby[name] then
        minetest.chat_send_player(name, "You're already in the lobby.")
        return
    end
    if count_keys(state.lobby) >= S.max_players then
        minetest.chat_send_player(name, "Lobby is full (" .. S.max_players .. " max).")
        return
    end
    state.lobby[name] = true
    local msg = format_message("joined_lobby", name, { count = count_keys(state.lobby), max = S.max_players })
    minetest.chat_send_all(msg)
    lobby_system.hud.flash_all(msg, 2)
    lobby_system.sounds.play_joined()
    lobby_system.gui.refresh_all()
end

function lobby_system.lobby.leave(name)
    if state.lobby[name] then
        state.lobby[name] = nil
        local msg = format_message("left_lobby", name, { count = count_keys(state.lobby), max = S.max_players })
        minetest.chat_send_all(msg)
        lobby_system.gui.refresh_all()
    else
        minetest.chat_send_player(name, "You're not in the lobby.")
    end
end

function lobby_system.lobby.start(caller_name)
    local g = game()
    if not g then return false, "No game is registered." end
    if state.phase ~= "lobby" then
        return false, "A match is already in progress."
    end
    local count = count_keys(state.lobby)
    if count < 1 then
        return false, "Need at least 1 player in the lobby (use join)."
    end
    if count < S.min_players then
        local is_admin = caller_name and minetest.check_player_privs(caller_name, { lobby_admin = true })
        if not is_admin then
            return false, "Need at least " .. S.min_players .. " players to start (an admin can start with fewer)."
        end
        minetest.chat_send_all("Starting with fewer than the usual " .. S.min_players
            .. " players (admin override).")
    end

    local lobby_snapshot = {}
    for n, _ in pairs(state.lobby) do lobby_snapshot[n] = true end
    state.phase = "countdown"
    state.countdown_left = S.countdown_seconds
    state.players = {}
    state.next_index = 1
    lobby_system.apply_pending_new_game()
    state.match_number = state.match_number + 1

    if g.on_match_prepare then
        g.on_match_prepare(count)
    end

    lobby_system.gui.on_match_start(lobby_snapshot)

    local i = 1
    for name, _ in pairs(lobby_snapshot) do
        lobby_system.lobby.start_one_player(name, i)
        i = i + 1
    end
    state.next_index = count + 1

    lobby_system.hud.update_all_scoreboards()
    lobby_system.lobby.run_countdown(S.countdown_seconds)
    return true
end

function lobby_system.lobby.start_with_confirmation(caller_name)
    local g = game()
    if not g then return false, "No game is registered." end
    if state.phase ~= "lobby" then
        return false, "A match is already in progress."
    end
    local count = count_keys(state.lobby)
    if count < 1 then
        return false, "Need at least 1 player in the lobby (use join)."
    end

    local is_admin = caller_name and minetest.check_player_privs(caller_name, { lobby_admin = true })
    if not is_admin and count < S.max_players then
        local not_joined = 0
        for _, p in ipairs(minetest.get_connected_players()) do
            if not state.lobby[p:get_player_name()] then
                not_joined = not_joined + 1
            end
        end
        if not_joined > 0 then
            lobby_system.gui.show_start_confirm(caller_name, not_joined)
            return true
        end
    end

    return lobby_system.lobby.start(caller_name)
end

function lobby_system.lobby.start_one_player(name, index)
    local g = game()
    state.players[name] = true
    state.racer_start_us[name] = minetest.get_us_time()

    local pos, yaw = idle_pos_and_yaw()
    if g.get_spawn then
        local p, y = g.get_spawn(index)
        if p then pos, yaw = p, y or 0 end
    end

    local player = minetest.get_player_by_name(name)
    if player then
        lobby_system.sounds.stop_lobby_loop(name)
    end
    g.on_match_start(name, index, pos, yaw)
end

function lobby_system.lobby.run_countdown(n)
    state.countdown_left = n

    if n <= 0 then
        state.phase = "playing"
        for _, player in ipairs(minetest.get_connected_players()) do
            lobby_system.hud.clear_status(player)
        end
        minetest.chat_send_all("GO!")
        lobby_system.hud.flash_all("GO!", 1.5)
        local g = game()
        if g and g.on_racing_started then g.on_racing_started() end
        return
    end

    for _, player in ipairs(minetest.get_connected_players()) do
        lobby_system.hud.set_status(player, tostring(n))
    end
    minetest.chat_send_all("Starting in " .. n .. "...")

    if n == S.late_join_cutoff then
        lobby_system.gui.refresh_non_players()
    end

    minetest.after(1, function() lobby_system.lobby.run_countdown(n - 1) end)
end


function lobby_system.get_last_match_duration(name)
    return lobby_system.last_match_duration[name]
end

local function record_match_duration(name)
    local start_us = state.racer_start_us[name]
    if start_us then
        lobby_system.last_match_duration[name] = (minetest.get_us_time() - start_us) / 1000000
        state.racer_start_us[name] = nil
    end
end

function lobby_system.player_died(name, message)
    record_match_duration(name)
    lobby_system.state.died_this_match[name] = true
    minetest.chat_send_all(message or (name .. " is out!"))
    lobby_system.hud.flash_all(message or (name .. " is out!"), 2.5)
    lobby_system.sounds.play_eliminated(name)
end

local pending_new_game = true

function lobby_system.apply_pending_new_game()
    if not pending_new_game then return false end
    pending_new_game = false
    lobby_system.setup_new_game()
    return true
end

function lobby_system.check_matches_per_game_winner()
    if pending_new_game then return nil end
    if not (S.matches_per_game and state.match_number >= S.matches_per_game) then
        return nil
    end

    local best_name, best_score = nil, -1
    for _, n in ipairs(lobby_system.all_known_players()) do
        local s = lobby_system.get_score(n)
        if s > best_score then
            best_name, best_score = n, s
        end
    end

    local message = nil
    if best_name then
        message = best_name .. " wins the game with " .. best_score .. " points!"
        lobby_system.sounds.play_won()
    end
    pending_new_game = true
    return message
end

function lobby_system.player_won(name, message, score_amount, flash_duration)
    state.phase = "ended"
    record_match_duration(name)
    lobby_system.add_score(name, score_amount or 1)

    message = message or (name .. " wins!")
    local overall_msg = lobby_system.check_overall_winner()
    if overall_msg then
        message = message .. "\n" .. overall_msg
    end

    minetest.chat_send_all(message)
    lobby_system.hud.flash_all(message, flash_duration or 4)
    lobby_system.sounds.play_won()
    lobby_system.hud.update_all_scoreboards()
end

function lobby_system.check_overall_winner()
    if pending_new_game then return nil end -- see the guard comment on check_matches_per_game_winner above - same reasoning
    if not S.score_to_win_game then return nil end
    local best_name, best_score = nil, -1
    for _, n in ipairs(lobby_system.all_known_players()) do
        local s = lobby_system.get_score(n)
        if s > best_score then
            best_name, best_score = n, s
        end
    end
    if best_name and best_score >= S.score_to_win_game then
        local msg = best_name .. " wins the game with " .. best_score .. " points!"
        lobby_system.sounds.play_won()
        pending_new_game = true
        return msg
    end
    return nil
end

function lobby_system.match_draw(message, flash_duration)
    state.phase = "ended"
    message = message or "No winner - the match ends in a draw."

    local overall_msg = lobby_system.check_overall_winner()
    if overall_msg then
        message = message .. "\n" .. overall_msg
        lobby_system.sounds.play_won()
    end

    minetest.chat_send_all(message)
    lobby_system.hud.flash_all(message, flash_duration or 4)
end

function lobby_system.game_over()
    local g = game()
    for name, _ in pairs(state.players) do
        if g and g.on_match_end then
            g.on_match_end(name)
        end
        state.racer_start_us[name] = nil
        local player = minetest.get_player_by_name(name)
        if player then
            local pos, yaw = idle_pos_and_yaw()
            player:set_pos(pos)
            player:set_look_horizontal(yaw)
            player:set_look_vertical(0)
            lobby_system.enter_idle_state(player)
            lobby_system.hud.clear_status(player)
            lobby_system.sounds.start_lobby_loop(player)
        end
    end
    state.players = {}
    state.next_index = 1
    state.phase = "lobby"
    state.died_this_match = {}

    if g and g.on_racing_ended then g.on_racing_ended() end

    local msg = lobby_system.check_matches_per_game_winner()
    if msg then
        minetest.chat_send_all(msg)
        lobby_system.hud.flash_all(msg, 6)
    end

    minetest.chat_send_all("Back to the lobby - join to play again!")

    for _, player in ipairs(minetest.get_connected_players()) do
        lobby_system.gui.show(player:get_player_name())
    end
end


minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    local was_racing = state.players[name] and true or false
    local was_in_lobby = state.lobby[name] and true or false

    if was_in_lobby then
        state.lobby[name] = nil
    end

    if was_racing then
        minetest.chat_send_all(format_message("left_game", name))
    elseif was_in_lobby then
        minetest.chat_send_all(format_message("left_lobby", name, { count = count_keys(state.lobby), max = S.max_players }))
    end

    if was_in_lobby then
        lobby_system.gui.refresh_all()
    end
end)

minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()

    if S.new_game_on_second_player then
        local other_players = 0
        for _, p in ipairs(minetest.get_connected_players()) do
            if p:get_player_name() ~= name then
                other_players = other_players + 1
            end
        end
        if other_players == 1 then
            lobby_system.setup_new_game()
            lobby_system.hud.update_all_scoreboards()
        end
    end

    if S.reset_score_on_join then
        lobby_system.reset_score(name)
        lobby_system.hud.update_all_scoreboards()
    end
    lobby_system.enter_idle_state(player)
    local pos, yaw = idle_pos_and_yaw()
    player:set_pos(pos)
    player:set_look_horizontal(yaw)

    if not state.players[name] then
        lobby_system.sounds.start_lobby_loop(player)
        lobby_system.gui.show(name)
    end

    minetest.after(0.5, function()
        local p = minetest.get_player_by_name(name)
        if p and p:is_player() and not state.players[name] then
            lobby_system.hide_player_body(p)
            lobby_system.hide_nametag(p)
        end
    end)
end)

local last_aux1 = {}
minetest.register_globalstep(function(dtime)
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        if not state.players[name] then
            local controls = player:get_player_control()
            if controls.aux1 and not last_aux1[name] then
                lobby_system.gui.show(name)
            end
            last_aux1[name] = controls.aux1
        else
            last_aux1[name] = nil
        end
    end
end)
