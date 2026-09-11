lobby_system = rawget(_G, "lobby_system") or {}


lobby_system.settings = {
    countdown_seconds = 5,
    late_join_cutoff = 2,   -- seconds left in the countdown when late-join closes
    max_players = 8,

    min_players = 2,

    score_to_win_game = nil,

    matches_per_game = nil,

    default_idle_pos = { x = 0, y = 50, z = 0 },
    default_idle_yaw = 0,

    hud_scale = 1.28,

    mobile_hud_scale_multiplier = 2 / 3,

    reset_score_on_join = false,

    new_game_on_second_player = false,

    sound = {
        joined_gain = 0.7,
        won_gain = 1.0,
        eliminated_gain = 1.0,
        lobby_gain = 0.35,
    },
}

lobby_system.state = {
    phase = "lobby",       -- "lobby" | "countdown" | "playing" | "ended"
    lobby = {},            -- name -> true, players waiting to play
    players = {},           -- name -> true, players in the current/forming match
    countdown_left = 0,
    next_index = 1,        -- next unused spawn/slot index, for late joins
    game = nil,             -- the currently registered game's config table
    racer_start_us = {},   -- name -> minetest.get_us_time() when they started this match
    match_number = 0,      -- how many matches have been played in the current session
    died_this_match = {},  -- name -> true, eliminated in the current/just-finished match -
    scores = {},            -- name -> integer score, this session only - see the note above
}

lobby_system.last_match_duration = {}


function lobby_system.get_score(name)
    return lobby_system.state.scores[name] or 0
end

function lobby_system.add_score(name, amount)
    lobby_system.state.scores[name] = lobby_system.get_score(name) + (amount or 1)
end

function lobby_system.reset_all_scores()
    lobby_system.state.scores = {}
end

function lobby_system.reset_score(name)
    lobby_system.state.scores[name] = nil
end

lobby_system.on_new_game_fn = nil

function lobby_system.set_on_new_game_fn(fn)
    lobby_system.on_new_game_fn = fn
end

function lobby_system.setup_new_game()
    lobby_system.reset_all_scores()
    lobby_system.state.match_number = 0
    lobby_system.state.died_this_match = {}
    if lobby_system.on_new_game_fn then lobby_system.on_new_game_fn() end
end

lobby_system.before_show_fn = nil

function lobby_system.set_before_show_fn(fn)
    lobby_system.before_show_fn = fn
end

function lobby_system.get_match_progress()
    return { current = lobby_system.state.match_number, total = lobby_system.settings.matches_per_game }
end


function lobby_system.is_mobile_player(name)
    local info = minetest.get_player_information and minetest.get_player_information(name)
    if not info then return false end
    if info.touch_controls ~= nil then return info.touch_controls end
    if info.platform then
        return info.platform:find("Android") ~= nil or info.platform:find("iOS") ~= nil
    end
    return false
end

function lobby_system.get_hud_scale(name)
    local S = lobby_system.settings
    local base = S.hud_scale or 1
    if lobby_system.is_mobile_player(name) then
        return base * (S.mobile_hud_scale_multiplier or 1)
    end
    return base
end

lobby_system.extra_known_names_fn = nil

function lobby_system.set_extra_known_names_fn(fn)
    lobby_system.extra_known_names_fn = fn
end

function lobby_system.all_known_players()
    local names = {}
    local seen = {}
    local function add(n)
        if n and not seen[n] then
            seen[n] = true
            table.insert(names, n)
        end
    end
    for n, _ in pairs(lobby_system.state.lobby) do add(n) end
    for n, _ in pairs(lobby_system.state.players) do add(n) end
    for _, p in ipairs(minetest.get_connected_players()) do add(p:get_player_name()) end
    if lobby_system.extra_known_names_fn then
        for _, n in ipairs(lobby_system.extra_known_names_fn() or {}) do add(n) end
    end
    return names
end
