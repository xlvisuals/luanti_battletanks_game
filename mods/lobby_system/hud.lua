
lobby_system.hud = {}
local hud_ids = {} -- name -> { scoreboard = id, status = id }

local function sz(name, x, y)
    local scale = lobby_system.get_hud_scale(name)
    return { x = x * scale, y = y * scale }
end

local function ids_for(name)
    hud_ids[name] = hud_ids[name] or {}
    return hud_ids[name]
end


local SCOREBOARD_DEFAULT_COLOR = "#E0FFFF"
local SCOREBOARD_DIED_COLOR = "#FF4040"

lobby_system.scoreboard_filter_fn = nil

function lobby_system.set_scoreboard_filter_fn(fn)
    lobby_system.scoreboard_filter_fn = fn
end

local function scoreboard_text()
    local names = lobby_system.all_known_players()
    if lobby_system.scoreboard_filter_fn then
        local filtered = {}
        for _, n in ipairs(names) do
            if lobby_system.scoreboard_filter_fn(n) then
                table.insert(filtered, n)
            end
        end
        names = filtered
    end
    table.sort(names, function(a, b)
        return lobby_system.get_score(a) > lobby_system.get_score(b)
    end)
    local title = "Scores"
    local lines = { minetest.colorize(SCOREBOARD_DEFAULT_COLOR, title) }
    for _, n in ipairs(names) do
        local line = string.format("%s: %d", n, lobby_system.get_score(n))
        local color = lobby_system.state.died_this_match[n]
            and SCOREBOARD_DIED_COLOR or SCOREBOARD_DEFAULT_COLOR
        table.insert(lines, minetest.colorize(color, line))
    end
    return table.concat(lines, "\n")
end

lobby_system.match_counter_suffix_fn = nil

function lobby_system.set_match_counter_suffix(fn)
    lobby_system.match_counter_suffix_fn = fn
end

local scoreboard_hidden = false
local match_counter_hidden = false

function lobby_system.hud.set_scoreboard_hidden(hidden)
    scoreboard_hidden = hidden
    lobby_system.hud.update_all_scoreboards()
end

function lobby_system.hud.set_match_counter_hidden(hidden)
    match_counter_hidden = hidden
    lobby_system.hud.update_all_scoreboards()
end

local function match_counter_text()
    if match_counter_hidden then return nil end
    local progress = lobby_system.get_match_progress()
    if not progress.total then return nil end
    local text = "Battle: " .. progress.current .. "/" .. progress.total
    if lobby_system.match_counter_suffix_fn then
        local suffix = lobby_system.match_counter_suffix_fn()
        if suffix then
            text = text .. " - " .. suffix
        end
    end
    return text
end

function lobby_system.hud.update_all_scoreboards()
    local text = scoreboard_text()
    local counter_text = match_counter_text()

    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local ids = ids_for(name)
        local scale = lobby_system.get_hud_scale(name)
        local scoreboard_offset_y = counter_text and (12 + 34 * scale) or 12

        if counter_text then
            if not ids.match_counter then
                ids.match_counter = player:hud_add({
                    type = "text",
                    position = { x = 1, y = 0 },
                    offset = { x = -12, y = 12 },
                    alignment = { x = -1, y = 1 },
                    number = 0xFFE080,
                    text = counter_text,
                    scale = { x = 100, y = 100 },
                    size = sz(name, 1.3, 1.3),
                })
            else
                player:hud_change(ids.match_counter, "text", counter_text)
            end
        elseif ids.match_counter then
            player:hud_remove(ids.match_counter)
            ids.match_counter = nil
        end

        if scoreboard_hidden then
            if ids.scoreboard then
                player:hud_remove(ids.scoreboard)
                ids.scoreboard = nil
            end
        elseif not ids.scoreboard then
            ids.scoreboard = player:hud_add({
                type = "text",
                position = { x = 1, y = 0 },
                offset = { x = -12, y = scoreboard_offset_y },
                alignment = { x = -1, y = 1 },
                number = 0xE0FFFF,
                text = text,
                scale = { x = 100, y = 100 },
                size = sz(name, 1.4, 1.4),
            })
        else
            player:hud_change(ids.scoreboard, "text", text)
            player:hud_change(ids.scoreboard, "offset", { x = -12, y = scoreboard_offset_y })
        end
    end
end


function lobby_system.hud.set_status(player, text)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.status then
        ids.status = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 0.35 },
            offset = { x = 0, y = 0 },
            alignment = { x = 0, y = 0 },
            number = 0xFFFFFF,
            text = text or "",
            scale = { x = 100, y = 100 },
            size = sz(name, 2.6, 2.6),
        })
    else
        player:hud_change(ids.status, "text", text or "")
    end
end

function lobby_system.hud.clear_status(player)
    lobby_system.hud.set_status(player, "")
end

local flash_all_job = nil

function lobby_system.hud.flash_all(text, seconds)
    if lobby_system.hide_flash_messages then return end -- see settings.lua's comment - suppresses every big on-screen notification uniformly, not just eliminations
    local names = {}
    for _, player in ipairs(minetest.get_connected_players()) do
        table.insert(names, player:get_player_name())
        lobby_system.hud.set_status(player, text)
    end
    if flash_all_job then
        flash_all_job:cancel()
    end
    flash_all_job = minetest.after(seconds or 3, function()
        flash_all_job = nil
        for _, name in ipairs(names) do
            local p = minetest.get_player_by_name(name)
            if p and p:is_player() then
                lobby_system.hud.clear_status(p)
            end
        end
    end)
end

minetest.register_on_leaveplayer(function(player)
    hud_ids[player:get_player_name()] = nil
end)

minetest.register_on_joinplayer(function(player)
    lobby_system.hud.update_all_scoreboards()
end)
