
battletanks.hud = {}
local hud_ids = {} -- name -> { boost_bg/boost_fill/boost_label = id, speed = id, battle_table = id, ... }

local function ids_for(name)
    hud_ids[name] = hud_ids[name] or {}
    return hud_ids[name]
end

function battletanks.hud.add_crosshair(player)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if ids.crosshair then return end
    local pos = player:get_pos() or { x = 0, y = 0, z = 0 }
    ids.crosshair = player:hud_add({
        type = "image_waypoint",
        world_pos = pos,
        alignment = { x = 0, y = 0 },
        offset = { x = 0, y = 0 },
        text = "battletanks_crosshair.png",
        scale = { x = 1, y = 1 },
        size = { x = 32, y = 32 }, -- matches the source texture 1:1 at scale 1 - explicit, rather than relying on a default
        z_index = 0, -- standard layer for crosshair/hotbar/statbar-type HUD elements
    })
end

function battletanks.hud.update_crosshair(player, world_pos)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.crosshair then return end
    player:hud_change(ids.crosshair, "world_pos", world_pos)
end

function battletanks.hud.remove_crosshair(player)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if ids.crosshair then
        player:hud_remove(ids.crosshair)
        ids.crosshair = nil
    end
end

local RACE_TABLE_COLOR = "#E0FFFF"
local RACE_TABLE_DIED_COLOR = "#FF4040"

local COL_GAP = 14
local COL_WIDTH = { gs = 55, rs = 50, rr = 40, name = 170 }
local function col_offset_x(scale, col)
    local x = -12
    local order = { "gs", "rs", "rr", "name" }
    for _, c in ipairs(order) do
        if c == col then return x * scale end
        x = x - COL_WIDTH[c] - COL_GAP
    end
end

local function battle_table_rows()
    local rows = {}
    for name, pdata in pairs(battletanks.players) do
        table.insert(rows, {
            name = name,
            rank = pdata.battle_rank,
            battle_score = pdata.battle_score,
            game_score = lobby_system.get_score(name),
            alive = pdata.alive,
        })
    end
    return rows
end

local function sort_battle_table_rows(rows)
    local phase = lobby_system.state.phase
    if phase == "playing" or phase == "countdown" then
        table.sort(rows, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.battle_score ~= b.battle_score then return a.battle_score > b.battle_score end
            if a.game_score ~= b.game_score then return a.game_score > b.game_score end
            return a.name < b.name
        end)
    elseif phase == "ended" then
        table.sort(rows, function(a, b)
            if a.battle_score ~= b.battle_score then return a.battle_score > b.battle_score end
            if a.game_score ~= b.game_score then return a.game_score > b.game_score end
            return a.name < b.name
        end)
    else -- "lobby"
        table.sort(rows, function(a, b)
            if a.game_score ~= b.game_score then return a.game_score > b.game_score end
            return a.name < b.name
        end)
    end
    return rows
end

local last_battle_rows = nil

function battletanks.hud.snapshot_battle_table()
    last_battle_rows = battle_table_rows()
end

local function current_battle_table_rows()
    local phase = lobby_system.state.phase
    local rows
    if phase == "playing" or phase == "countdown" then
        rows = battle_table_rows()
    elseif phase == "ended" then
        rows = last_battle_rows or {}
    else
        rows = {}
        for _, r in ipairs(last_battle_rows or {}) do
            table.insert(rows, {
                name = r.name,
                rank = r.rank,
                battle_score = r.battle_score,
                game_score = lobby_system.get_score(r.name),
                alive = r.alive,
            })
        end
    end
    return sort_battle_table_rows(rows)
end

local function battle_table_column_texts()
    local rows = current_battle_table_rows()
    local cols = {
        name = { minetest.colorize(RACE_TABLE_COLOR, "Name") },
        rr = { minetest.colorize(RACE_TABLE_COLOR, "BR") },
        rs = { minetest.colorize(RACE_TABLE_COLOR, "BS") },
        gs = { minetest.colorize(RACE_TABLE_COLOR, "GS") },
    }
    for _, r in ipairs(rows) do
        local color = r.alive and RACE_TABLE_COLOR or RACE_TABLE_DIED_COLOR
        local displayed_rank = r.rank == 0 and "" or tostring(r.rank)
        table.insert(cols.name, minetest.colorize(color, r.name))
        table.insert(cols.rr, minetest.colorize(color, displayed_rank))
        table.insert(cols.rs, minetest.colorize(color, tostring(r.battle_score)))
        table.insert(cols.gs, minetest.colorize(color, tostring(r.game_score)))
    end
    return {
        name = table.concat(cols.name, "\n"),
        rr = table.concat(cols.rr, "\n"),
        rs = table.concat(cols.rs, "\n"),
        gs = table.concat(cols.gs, "\n"),
    }
end

function battletanks.hud.update_battle_table()
    local texts = battle_table_column_texts()
    for _, player in ipairs(minetest.get_connected_players()) do
        local ids = ids_for(player:get_player_name())
        if ids.battle_table_name then
            player:hud_change(ids.battle_table_name, "text", texts.name)
            player:hud_change(ids.battle_table_rr, "text", texts.rr)
            player:hud_change(ids.battle_table_rs, "text", texts.rs)
            player:hud_change(ids.battle_table_gs, "text", texts.gs)
        end
    end
end

local battle_table_wanted = false

local battle_table_admin_hidden = false

local function apply_battle_table_visibility(player)
    local name = player:get_player_name()
    local ids = ids_for(name)
    local should_show = battle_table_wanted and not battle_table_admin_hidden
    if should_show then
        if not ids.battle_table_name then
            local scale = lobby_system.get_hud_scale(name)
            local texts = battle_table_column_texts()
            local y = (12 + 34 * scale)
            local size = { x = 1.1 * scale, y = 1.1 * scale }
            ids.battle_table_name = player:hud_add({
                type = "text", position = { x = 1, y = 0 }, alignment = { x = -1, y = 1 },
                offset = { x = col_offset_x(scale, "name"), y = y },
                number = 0xE0FFFF, text = texts.name, scale = { x = 100, y = 100 }, size = size,
            })
            ids.battle_table_rr = player:hud_add({
                type = "text", position = { x = 1, y = 0 }, alignment = { x = -1, y = 1 },
                offset = { x = col_offset_x(scale, "rr"), y = y },
                number = 0xE0FFFF, text = texts.rr, scale = { x = 100, y = 100 }, size = size,
            })
            ids.battle_table_rs = player:hud_add({
                type = "text", position = { x = 1, y = 0 }, alignment = { x = -1, y = 1 },
                offset = { x = col_offset_x(scale, "rs"), y = y },
                number = 0xE0FFFF, text = texts.rs, scale = { x = 100, y = 100 }, size = size,
            })
            ids.battle_table_gs = player:hud_add({
                type = "text", position = { x = 1, y = 0 }, alignment = { x = -1, y = 1 },
                offset = { x = col_offset_x(scale, "gs"), y = y },
                number = 0xE0FFFF, text = texts.gs, scale = { x = 100, y = 100 }, size = size,
            })
        end
    elseif ids.battle_table_name then
        for _, id_key in ipairs({ "battle_table_name", "battle_table_rr", "battle_table_rs", "battle_table_gs" }) do
            player:hud_remove(ids[id_key])
            ids[id_key] = nil
        end
    end
end

function battletanks.hud.set_battle_table_visible(player, visible)
    lobby_system.hud.set_scoreboard_hidden(visible)
    battle_table_wanted = visible
    apply_battle_table_visibility(player)
end

function battletanks.hud.set_battle_table_admin_hidden(hidden)
    battle_table_admin_hidden = hidden
    for _, player in ipairs(minetest.get_connected_players()) do
        apply_battle_table_visibility(player)
    end
end

local BAR_TEXTURE_W, BAR_TEXTURE_H = 4, 16
local BAR_WIDTH, BAR_HEIGHT = 220, 22 -- on-screen pixels at hud_scale = 1
local BAR_GAP = 10 -- space between the "Boost:" label and the bar's own left edge

local function boost_bg_params(hud_scale)
    return {
        offset = { x = 0, y = 20 * hud_scale },
        scale = { x = (BAR_WIDTH * hud_scale) / BAR_TEXTURE_W, y = (BAR_HEIGHT * hud_scale) / BAR_TEXTURE_H },
    }
end

local function boost_fill_params(hud_scale, percent)
    percent = math.max(0, math.min(100, percent or 0))
    return {
        offset = { x = -(BAR_WIDTH * hud_scale) / 2, y = 20 * hud_scale },
        scale = {
            x = (BAR_WIDTH * hud_scale * (percent / 100)) / BAR_TEXTURE_W,
            y = (BAR_HEIGHT * hud_scale) / BAR_TEXTURE_H,
        },
    }
end

function battletanks.hud.set_boost_visible(player, visible)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if visible then
        battletanks.hud.add_boost_bar(player)
        local pdata = battletanks.players[name]
        if pdata then
            battletanks.hud.update_boost_bar(player, pdata.boost)
        end
    else
        for _, id_key in ipairs({ "boost_bg", "boost_fill", "boost_label", "speed" }) do
            if ids[id_key] then
                player:hud_remove(ids[id_key])
                ids[id_key] = nil
            end
        end
    end
end

function battletanks.hud.add_boost_bar(player)
    local name = player:get_player_name()
    local ids = ids_for(name)
    local scale = lobby_system.get_hud_scale(name)

    if not ids.boost_bg then
        local p = boost_bg_params(scale)
        ids.boost_bg = player:hud_add({
            type = "image",
            position = { x = 0.5, y = 0 },
            offset = p.offset,
            alignment = { x = 0, y = 1 },
            text = "battletanks_boost_bar_bg.png",
            scale = p.scale,
        })
    end
    if not ids.boost_fill then
        local p = boost_fill_params(scale, 0)
        ids.boost_fill = player:hud_add({
            type = "image",
            position = { x = 0.5, y = 0 },
            offset = p.offset,
            alignment = { x = 1, y = 1 },
            text = "battletanks_boost_bar_fill.png",
            scale = p.scale,
        })
    end
    local bar_mid_y = (20 + BAR_HEIGHT / 2) * scale
    local bar_half_w = (BAR_WIDTH / 2) * scale
    if not ids.boost_label then
        ids.boost_label = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 0 },
            offset = { x = -bar_half_w - BAR_GAP * scale, y = bar_mid_y },
            alignment = { x = -1, y = 0 },
            number = 0xFFFFFF,
            text = "Boost:",
            scale = { x = 100, y = 100 },
            size = { x = 1.4 * scale, y = 1.4 * scale },
        })
    end
    if not ids.speed then
        ids.speed = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 0 },
            offset = { x = 0, y = (20 + BAR_HEIGHT + 11) * scale },
            alignment = { x = 0, y = 1 },
            number = 0xFFFFFF,
            text = "Speed: 100",
            scale = { x = 100, y = 100 },
            size = { x = 1.4 * scale, y = 1.4 * scale },
        })
    end

    local SLOT_SPACING = 70
    local BADGE_OFFSET = 18
    if not ids.shield_icon then
        ids.shield_icon = player:hud_add({
            type = "image",
            position = { x = 0.5, y = 1 },
            offset = { x = -SLOT_SPACING * scale, y = -60 * scale },
            alignment = { x = 0, y = 0 },
            text = "", -- empty = invisible until at least one shield is held
            scale = { x = 3 * scale, y = 3 * scale },
        })
    end
    if not ids.shield_count then
        ids.shield_count = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 1 },
            offset = { x = (-SLOT_SPACING + BADGE_OFFSET) * scale, y = -42 * scale },
            alignment = { x = -1, y = 1 },
            number = 0xFFFFFF,
            text = "",
            scale = { x = 100, y = 100 },
            size = { x = 1.1 * scale, y = 1.1 * scale },
        })
    end
    if not ids.laser_icon then
        ids.laser_icon = player:hud_add({
            type = "image",
            position = { x = 0.5, y = 1 },
            offset = { x = 0, y = -60 * scale },
            alignment = { x = 0, y = 0 },
            text = "", -- empty = invisible until at least one shot is held
            scale = { x = 3 * scale, y = 3 * scale },
        })
    end
    if not ids.laser_count then
        ids.laser_count = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 1 },
            offset = { x = BADGE_OFFSET * scale, y = -42 * scale },
            alignment = { x = -1, y = 1 },
            number = 0xFFFFFF,
            text = "",
            scale = { x = 100, y = 100 },
            size = { x = 1.1 * scale, y = 1.1 * scale },
        })
    end
    if not ids.rocket_icon then
        ids.rocket_icon = player:hud_add({
            type = "image",
            position = { x = 0.5, y = 1 },
            offset = { x = SLOT_SPACING * scale, y = -60 * scale },
            alignment = { x = 0, y = 0 },
            text = "", -- empty = invisible until at least one rocket is held
            scale = { x = 3 * scale, y = 3 * scale },
        })
    end
    if not ids.rocket_count then
        ids.rocket_count = player:hud_add({
            type = "text",
            position = { x = 0.5, y = 1 },
            offset = { x = (SLOT_SPACING + BADGE_OFFSET) * scale, y = -42 * scale },
            alignment = { x = -1, y = 1 },
            number = 0xFFFFFF,
            text = "",
            scale = { x = 100, y = 100 },
            size = { x = 1.1 * scale, y = 1.1 * scale },
        })
    end
    local flags = player:hud_get_flags()
    flags.hotbar = false
    flags.healthbar = false
    flags.crosshair = false -- using our own screen-centered crosshair instead - see add_crosshair's comment
    player:hud_set_flags(flags)
    battletanks.hud.add_crosshair(player)
end

function battletanks.hud.update_boost_bar(player, percent)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.boost_fill then return end
    percent = math.max(0, math.min(100, percent or 0))
    local scale = lobby_system.get_hud_scale(name)
    local p = boost_fill_params(scale, percent)
    player:hud_change(ids.boost_fill, "scale", p.scale)
end

function battletanks.hud.update_speed(player, speed_percent)
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.speed then return end
    player:hud_change(ids.speed, "text", "Speed: " .. math.floor(speed_percent + 0.5))
end

function battletanks.hud.update_shield(player, count)
    if not player then return end
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.shield_icon or not ids.shield_count then return end
    if count and count > 0 then
        player:hud_change(ids.shield_icon, "text", "battletanks_powerup_shield.png")
        player:hud_change(ids.shield_count, "text", count >= 2 and ("x" .. count) or "")
    else
        player:hud_change(ids.shield_icon, "text", "")
        player:hud_change(ids.shield_count, "text", "")
    end
end

function battletanks.hud.update_laser(player, count)
    if not player then return end
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.laser_icon or not ids.laser_count then return end
    if count and count > 0 then
        player:hud_change(ids.laser_icon, "text", "battletanks_powerup_laser.png")
        player:hud_change(ids.laser_count, "text", count >= 2 and ("x" .. count) or "")
    else
        player:hud_change(ids.laser_icon, "text", "")
        player:hud_change(ids.laser_count, "text", "")
    end
end

function battletanks.hud.update_rocket(player, count)
    if not player then return end
    local name = player:get_player_name()
    local ids = ids_for(name)
    if not ids.rocket_icon or not ids.rocket_count then return end
    if count and count > 0 then
        player:hud_change(ids.rocket_icon, "text", "battletanks_powerup_rocket.png")
        player:hud_change(ids.rocket_count, "text", count >= 2 and ("x" .. count) or "")
    else
        player:hud_change(ids.rocket_icon, "text", "")
        player:hud_change(ids.rocket_count, "text", "")
    end
end

function battletanks.hud.remove_boost_bar(player)
    local name = player:get_player_name()
    local ids = ids_for(name)
    for _, id_key in ipairs({ "boost_bg", "boost_fill", "boost_label", "speed" }) do
        if ids[id_key] then
            player:hud_remove(ids[id_key])
            ids[id_key] = nil
        end
    end
    if ids.shield_icon then
        player:hud_remove(ids.shield_icon)
        ids.shield_icon = nil
    end
    if ids.shield_count then
        player:hud_remove(ids.shield_count)
        ids.shield_count = nil
    end
    if ids.laser_icon then
        player:hud_remove(ids.laser_icon)
        ids.laser_icon = nil
    end
    if ids.laser_count then
        player:hud_remove(ids.laser_count)
        ids.laser_count = nil
    end
    if ids.rocket_icon then
        player:hud_remove(ids.rocket_icon)
        ids.rocket_icon = nil
    end
    if ids.rocket_count then
        player:hud_remove(ids.rocket_count)
        ids.rocket_count = nil
    end
    local flags = player:hud_get_flags()
    flags.hotbar = true
    flags.healthbar = true
    flags.crosshair = false
    player:hud_set_flags(flags)
    battletanks.hud.remove_crosshair(player)
end

minetest.register_on_leaveplayer(function(player)
    hud_ids[player:get_player_name()] = nil
end)
