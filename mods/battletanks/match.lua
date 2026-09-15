
local S = battletanks.settings
local alive_count = 0

local function starting_value(enabled, value)
    return enabled and value or 0
end

local finish_match

battletanks.elimination_batches = {}


local function spawn_bots(real_count)
    if S.bot_count <= 0 then return end

    local spawn_points = battletanks.spawn_points()
    local max_total = math.min(#spawn_points, #S.colors)
    local bot_total = math.max(0, math.min(S.bot_count, max_total - real_count))
    if bot_total <= 0 then return end

    for i = 1, bot_total do
        local index = max_total - i + 1
        if index <= real_count then break end
        local sp = spawn_points[index]
        if not sp then break end

        local behavior = battletanks.bots.resolve_behavior(i)
        local bot_name = "Bot " .. i .. " (" .. battletanks.bots.behavior_letter(behavior) .. ")"
        local color = S.colors[index]


        local pdata = {
            color = color,
            alive = true,
            racing = true,
            yaw = sp.yaw,
            boost = starting_value(S.boost_powerups_enabled, S.starting_boost),
            was_left = false,
            was_right = false,
            tank_obj = nil,
            turret_obj = nil,
            engine_pitch_state = nil, -- nil means "not currently playing the loop sound"
            laser = starting_value(S.laser_powerups_enabled, S.starting_laser),
            laser_cooldown_remaining = 0,
            shield = starting_value(S.shield_powerups_enabled, S.starting_shield),
            rocket = starting_value(S.rocket_powerups_enabled, S.starting_rocket),
            rocket_cooldown_remaining = 0,
            is_bot = true,
            bot_behavior = behavior,
            battle_rank = 0,
            battle_score = 0,
        }
        battletanks.players[bot_name] = pdata
        alive_count = alive_count + 1

        pdata.tank_obj = battletanks.spawn_bot_tank(bot_name, color, sp.pos, sp.yaw)
        if pdata.tank_obj then
            pdata.turret_obj = battletanks.spawn_turret(pdata.tank_obj, color)
            battletanks.spawn_recognizer_if_enabled(bot_name, sp.pos)
        end
    end
end

local function despawn_all_bots()
    for name, pdata in pairs(battletanks.players) do
        if pdata.is_bot then
            battletanks.sounds.stop_engine_loop(name)
            battletanks.despawn_tank(nil, pdata)
            battletanks.despawn_recognizer_for(name)
            battletanks.players[name] = nil
        end
    end
end


local function mark_eliminated(name, custom_message)
    local pdata = battletanks.players[name]
    if not pdata or not pdata.alive then return end

    pdata.alive = false
    alive_count = alive_count - 1

    local player = minetest.get_player_by_name(name)
    local crash_pos = pdata.tank_obj and pdata.tank_obj:get_pos()
    battletanks.sounds.stop_engine_loop(name)
    battletanks.despawn_tank(player, pdata)
    battletanks.on_tank_eliminated_for_recognizer(name)
    if crash_pos then
        battletanks.spawn_crash_effect(crash_pos, pdata.color)
    end
    if player then
        player:set_velocity({ x = 0, y = 0, z = 0 })
        battletanks.enter_spectate(player, pdata)
    end

    lobby_system.player_died(name, custom_message or (name .. " was derezzed"))
end

local pending_decision = false

local function finalize_decision()
    pending_decision = false
    if lobby_system.state.phase ~= "playing" then return end -- already ended some other way

    local winner = nil
    local alive_now = 0
    local still_alive = {}
    local human_alive = false
    for n, p in pairs(battletanks.players) do
        if p.alive then
            alive_now = alive_now + 1
            winner = n
            table.insert(still_alive, n)
            if not p.is_bot then human_alive = true end
        end
    end

    if alive_now <= 1 then
        battletanks.end_match(winner) -- nil (draw) if alive_now == 0
    elseif not human_alive and not S.allow_bots_only_match then
        finish_match(still_alive, "No humans left playing - " .. #still_alive .. " bot"
            .. (#still_alive == 1 and "" or "s") .. " tie for the win.")
    end
end

local function any_human_alive()
    if S.allow_bots_only_match then return true end -- pretend there's always "a human" - see the setting's comment
    for n, p in pairs(battletanks.players) do
        if p.alive and not p.is_bot then return true end
    end
    return false
end

local function check_for_winner()
    if not pending_decision and (alive_count <= 1 or not any_human_alive()) then
        pending_decision = true
        minetest.after(S.mutual_elimination_grace, finalize_decision)
    end
end

local function assign_battle_rank(names)
    for _, name in ipairs(names) do
        local pdata = battletanks.players[name]
        if pdata and pdata.alive then
            pdata.battle_rank = alive_count
        end
    end
end

function battletanks.is_admin_invincible(name)
    return S.admin_invincible and minetest.check_player_privs(name, { lobby_admin = true })
end

local last_invincible_notice_us = {} -- name -> time of last chat notice, to avoid spamming it every tick

local function notify_invincible_survival(name)
    local now = minetest.get_us_time()
    if not last_invincible_notice_us[name] or (now - last_invincible_notice_us[name]) > 2000000 then
        last_invincible_notice_us[name] = now
        minetest.chat_send_all("[BattleTanks] " .. name .. " would have been derezzed, but admin_invincible is on.")
    end
end

function battletanks.eliminate(name, custom_message)
    if battletanks.is_admin_invincible(name) then
        notify_invincible_survival(name)
        return
    end
    assign_battle_rank({ name })
    mark_eliminated(name, custom_message)
    table.insert(battletanks.elimination_batches, { name })
    battletanks.hud.update_battle_table()
    check_for_winner()
end

function battletanks.eliminate_batch(names)
    local survivors = {}
    for _, name in ipairs(names) do
        if battletanks.is_admin_invincible(name) then
            notify_invincible_survival(name)
        else
            table.insert(survivors, name)
        end
    end
    if #survivors == 0 then return end

    assign_battle_rank(survivors)
    for _, name in ipairs(survivors) do
        mark_eliminated(name)
    end
    table.insert(battletanks.elimination_batches, survivors)
    battletanks.hud.update_battle_table()
    check_for_winner()
end


local function count_players()
    local n = 0
    for _ in pairs(battletanks.players) do n = n + 1 end
    return n
end

local function award_match_points(top_tier_names)
    if top_tier_names == nil then return end

    local tiers = { top_tier_names }
    for i = #battletanks.elimination_batches, 1, -1 do
        table.insert(tiers, battletanks.elimination_batches[i])
    end

    for tier_index, names in ipairs(tiers) do
        local points = S.placement_points[tier_index] or 0
        for _, name in ipairs(names) do
            if points > 0 then
                lobby_system.add_score(name, points)
                local pdata = battletanks.players[name]
                if pdata then
                    pdata.battle_score = pdata.battle_score + points
                    minetest.log("action", string.format("[battletanks] Awarded %d points to '" .. name .. "'. Total: %d", points, pdata.battle_score))
                end
            end
        end
    end
end


battletanks.match_generation = 0

local match_start_us = nil      -- set in on_match_prepare, i.e. roughly when Start was clicked
local last_match_duration = nil -- seconds (integer), the most recently *completed* match's duration

local function elapsed_battle_seconds()
    if not match_start_us then return 0 end
    local elapsed = (minetest.get_us_time() - match_start_us) / 1000000 - lobby_system.settings.countdown_seconds
    return math.max(0, math.floor(elapsed))
end

lobby_system.set_match_counter_suffix(function()
    local phase = lobby_system.state.phase
    if phase == "playing" or phase == "countdown" then
        local elapsed = elapsed_battle_seconds()
        if S.match_max_duration then
            return math.max(0, S.match_max_duration - elapsed) .. "s"
        end
        return elapsed .. "s"
    elseif last_match_duration then
        return last_match_duration .. "s"
    end
    return nil
end)

lobby_system.set_scoreboard_filter_fn(function(name)
    return lobby_system.state.lobby[name] or lobby_system.state.players[name] or false
end)

local timeout_job = nil
local clock_tick_job = nil

local function match_clock_tick(generation)
    if battletanks.match_generation ~= generation then return end
    local phase = lobby_system.state.phase
    if phase ~= "playing" and phase ~= "countdown" then return end
    lobby_system.hud.update_all_scoreboards()
    battletanks.hud.update_battle_table()
    clock_tick_job = minetest.after(1, function() match_clock_tick(generation) end)
end

finish_match = function(top_tier_names, message)
    if timeout_job then
        timeout_job:cancel(); timeout_job = nil
    end
    if clock_tick_job then
        clock_tick_job:cancel(); clock_tick_job = nil
    end
    battletanks.stop_boost_powerup_loop()
    battletanks.stop_shield_powerup_loop()
    battletanks.stop_laser_powerup_loop()
    battletanks.stop_rocket_powerup_loop()
    battletanks.despawn_point_powerup_entities()
    battletanks.clear_all_projectiles()

    for name, pdata in pairs(battletanks.players) do
        pdata.racing = false -- stops movement.lua's globalstep touching them further
        if pdata.tank_obj then
            pdata.tank_obj:set_velocity({ x = 0, y = 0, z = 0 })
        end
        if pdata.turret_obj then
            pdata.turret_obj:set_velocity({ x = 0, y = 0, z = 0 })
        end
        battletanks.sounds.stop_engine_loop(name)
    end
    battletanks.clear_active_boost_powerup()

    last_match_duration = elapsed_battle_seconds()

    if top_tier_names then
        for _, name in ipairs(top_tier_names) do
            local pdata = battletanks.players[name]
            if pdata then pdata.battle_rank = 1 end
        end
    end

    minetest.log("action", string.format("[battletanks] Match over"))
    award_match_points(top_tier_names)
    lobby_system.hud.update_all_scoreboards()
    battletanks.hud.update_battle_table()
    battletanks.hud.snapshot_battle_table()

    local full_message = message .. " (" .. last_match_duration .. "s)"

    local overall_message = lobby_system.check_overall_winner()
    if overall_message then
        full_message = full_message .. "\n" .. overall_message
    end
    local game_over_message = lobby_system.check_matches_per_game_winner()
    if game_over_message then
    	minetest.log("action", string.format("[battletanks] Game over"))
        full_message = full_message .. "\n" .. game_over_message
    end
    local session_ended = overall_message or game_over_message

    local return_delay = session_ended and 10 or 6

    local flash_duration = return_delay

    if top_tier_names and #top_tier_names == 1 then
        lobby_system.player_won(top_tier_names[1], full_message, 0, flash_duration)
    else
        lobby_system.match_draw(full_message, flash_duration)
    end

    minetest.after(return_delay, function()
        lobby_system.game_over()
        despawn_all_bots()
    end)
end

function battletanks.end_match(winner)
    local top_tier
    if winner then
        top_tier = { winner }
    elseif count_players() > 1 then
        top_tier = {}
    end -- else: solo draw, top_tier stays nil - no placement scoring

    local message = winner and (winner .. " wins the match!")
        or "No survivors - the match ends in a draw."
    finish_match(top_tier, message)
end

function battletanks.end_match_timeout()
    local still_alive = {}
    for name, pdata in pairs(battletanks.players) do
        if pdata.alive then table.insert(still_alive, name) end
    end

    if count_players() <= 1 then
        finish_match(nil, "Time's up! No survivors bonus for a solo run.")
    else
        finish_match(still_alive, "Time's up! " .. #still_alive .. " rider"
            .. (#still_alive == 1 and "" or "s") .. " tie for the win.")
    end
end

local HELP_FORMNAME = "battletanks:help"

local function help_formspec()
    local text = table.concat({
        "\n",
        "BattleTanks is a 3D multiplayer Tron-style tank battle game: drive through a maze arena, aim your turret freely with the mouse, and derez opponents with laser and rocket fire. Driving into a wall or another tank just stops you - only getting shot (or driving into a pit, on maps that have one) eliminates you. Shots bounce off walls instead of being destroyed by them, so you can bank a shot around a corner.\n",
		"\n",
		"<b>Controls</b>\n",
		"- A / D : turn 90 degrees left or right.\n",
		"- W : drive forward.\n",
		"- S : drive backward (slower than forward).\n",
		"- Mouse : aim your turret - independent of which way your tank is facing.\n",
		"- Shift (hold) : boost, while your boost bar isn't empty.\n",
		"- Space or Left-click : fire a laser shot (requires laser).\n",
		"- E (Aux key) or Right-click : fire a rocket (requires rocket) while racing. Outside of a battle, E instead reopens the lobby menu.\n",
		"- C : change camera view.\n",
		"\n",
		"<b>Scoring</b>\n",
		"Every racer scores points based on where they finished: \n",
		"- 1st place : " .. S.placement_points[1] .. "\n",
		"- 2nd place : " .. S.placement_points[2] .. "\n",
		"- 3rd place : " .. S.placement_points[3] .. "\n",
		"- 4th place : " .. S.placement_points[4] .. "\n",
		"- 5th place : " .. S.placement_points[5] .. "\n",
		"- 6th place : " .. S.placement_points[6] .. "\n",
		"- 7th place : " .. S.placement_points[7] .. "\n",
		"- 8th place : " .. S.placement_points[8] .. "\n",
		"A round with no survivors doesn't award 1st place to anyone, since nobody actually won. Players that are eliminated simultaneously occupy the same rank, and the next rank down is vacant.\n",
		"Collecting a point powerup awards " .. S.point_powerup_value .. " additional points.\n",
        "Eliminating an opponent with a shot (laser or rocket) awards " .. S.kill_by_shot_points .. " additional points.\n",
        "\n",
		"<b>Score table</b>\n",
        "The score table shows each racer's name, rank in the current battle, battle score (including awarded points), and overall game score: \n",
        "- Name : Player name.\n",
        "- BR : Battle Rank - the rank in the current battle.\n",
		"- BS : Battle Score - points earned in the current battle. Battle Rank points are awarded at the end of the battle.\n",
		"- GS : Game Score - sum of all Battle Scores.\n",
		"\n",
		"<b>Powerups</b>\n",
		"- Point powerup : collect it for " .. S.point_powerup_value .. " extra points. Does not respawn.\n",
		"- Boost powerup : instantly fills your boost bar.\n",
		"- Shield powerup : absorbs one incoming laser or rocket hit that would otherwise derez you.\n",
		"- Laser powerup : grants " .. S.laser_per_pickup .. " shots. \n",
		"- Rocket powerup : grants " .. S.rocket_per_pickup .. " rockets. \n",
		" A rocket is slower than a laser, but destroys a 3x3 area on impact instead of a single block, and eliminates anyone else caught in the blast too.\n",
		"\n",
		"<b>Recognizers</b>\n",
		"Admins can turn these on from the lobby panel: one flying sentry per tank, patrolling above the maze and tracking it from the air. Sit in one spot too long and the Recognizer hunting you will catch up and stomp you.\n",
		"Your cannon can't normally aim upward, but aiming at the ground directly beneath a Recognizer - and not at a tank - locks your crosshair onto it instead, so your next laser or rocket shot fires upward and hits it. This only works from a certain distance out: a Recognizer flying close or directly overhead is too steep an angle for the cannon to reach.\n",
		"A Recognizer takes three hits to bring down - one for each leg, then the body. Destroying one awards " .. S.recognizer_points .. " points and starts a " .. S.recognizer_respawn_time .. "-second respawn timer.\n",
		"\n",
		"<b>Player chat commands</b>\n",
		"- /bt or /bt menu : opens the lobby panel\n",
		"- /bt join : join the lobby.\n",
		"- /bt leave : leave the lobby.\n",
		"- /bt start : start a match.\n",
		"- /bt score : shows your score.\n",
		"- /bt help : opens the in-game help screen\n",
		"\n",
		"<b>Admin chat commands (admin only)</b>\n",
		"- /btspawns : lists the spawn points of the current map.\n",
		"- /btspawns <1-8> : teleports you to that exact spawn point, facing the way that racer would.\n",
		"- /btpause : Pauses game movement and grants free look and move to the admin. Run it again to resume the game. The game clock is not stopped during pause.\n",
		"- /bt show [score|names|battle|boost|messages|all] : Show the player names above the battletanks, the Scores list, the Battle number indicator, the boost bar, big on-screen flash notifications, or all (default).\n",
		"- /bt hide [score|names|battle|boost|messages|all] : Hide the same - hiding messages leaves chat lines and sounds alone, just not the big flash text covering the screen (eliminations, GO!, win announcements, etc).\n",
		"\n",
		"<b>Building custom maps</b>\n",
		"Clicking the 'Build Mode' button in the lobby grants fly/noclip/give permissions and hands you the tools to edit the arena:\n",
		"- Disc : a fast-digging tool.\n",
		"- Wall : ground and boundary block, right-click to place - use it to lay out a maze's internal walls too.\n",
		"- point-powerup spawner : place to spawn a point powerup above it.\n",
		"- 8 numbered player-spawn markers : place to spawn a player above it.\n",
		"Place point/player spawners on the ground level - same height as wall blocks, the point powerups and players will spawn above the spawner. Players spawn facing the direction you faced when placing the player spawner.\n",
		"Other powerups (shield, laser, rocket, boost) appear randomly on the map and don't require spawners.\n",
		"Once you're happy with a layout, return to the lobby ('E') and press 'Save Map' to save the nap under a new name. This captures the current arena as a .mts schematic in the world folder. You can then select the map from the map dropdown immediately.\n",
		"\n"
        }, "")
    minetest.log("action", "BattleTanks - Help:\n\n" .. text)

    return {
        "formspec_version[4]",
        "size[9,10]",
        "bgcolor[#000000AD]", -- Background. Default is bgcolor[#000000AA]
        "label[0.4,0.5;BattleTanks - Help]",
        "button_exit[6.6,0.3;2,0.6;lc_help_close;Close]",
        "hypertext[0.4,1.2;8.2,8.3;lc_help_text;" .. minetest.formspec_escape(text) .. "]",
    }
end

function battletanks.show_help(name)
    minetest.show_formspec(name, HELP_FORMNAME, table.concat(help_formspec(), ""))
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= HELP_FORMNAME then return end
    local name = player:get_player_name()
    lobby_system.gui.show(name)
    return true
end)


local EXPORT_FORMNAME = "battletanks:export_map"

local function export_map_formspec()
    local prefix = battletanks.export_map_prefix()

    return {
        "formspec_version[4]",
        "size[8,4.2]",
        "bgcolor[#000000AD]", -- Background. Default is bgcolor[#000000AA]
        "label[0.4,0.6;Save Current Map]",
        "label[0.4,1.5;Filename: " .. minetest.formspec_escape(prefix) .. "<name>.mts]",
        "label[0.4,2.2;Name:]",
        "field[1.4,1.9;6.3,0.7;lc_export_name;;]",
        "set_focus[lc_export_name]",
        "button[0.4,3.2;3.6,0.8;lc_export_confirm;Save]",
        "button[4.2,3.2;3.6,0.8;lc_export_cancel;Cancel]",
    }
end

function battletanks.show_export_map(name)
    minetest.show_formspec(name, EXPORT_FORMNAME, table.concat(export_map_formspec(), ""))
end

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= EXPORT_FORMNAME then return end
    local name = player:get_player_name()
    local is_admin = minetest.check_player_privs(name, { lobby_admin = true })
    local exporting = false

    if is_admin and (fields.lc_export_confirm or fields.key_enter_field == "lc_export_name") then
        local filename, err = battletanks.export_map_filename(fields.lc_export_name)
        if filename then
            exporting = true
            minetest.chat_send_player(name, "[BattleTanks] Saving current map as '" .. filename .. "'...")
            battletanks.export_current_map(filename, function(ok, message)
                minetest.chat_send_all("[BattleTanks] " .. name .. ": " .. message)
                if minetest.get_player_by_name(name) then
                    lobby_system.gui.show(name)
                end
            end)
        else
            minetest.chat_send_player(name, "[BattleTanks] Save failed - " .. err .. ".")
        end
    end

    if not exporting then
        lobby_system.gui.show(name)
    end
    return true
end)


lobby_system.register_game({
    title = S.title or "BattleTanks",
    command = "bt",
    max_players = #S.colors,
    matches_per_game = S.matches_per_session,
    show_help = battletanks.show_help,
    on_extra_command = function(name, param)
        return battletanks.handle_ui_command and battletanks.handle_ui_command(name, param)
    end,

    get_idle_pos = function()
        return battletanks.lobby_pos(), 0
    end,

    get_spawn = function(index)
        local sp = battletanks.spawn_points()[index]
        return sp.pos, sp.yaw
    end,

    on_match_prepare = function(count)
        alive_count = 0
        battletanks.elimination_batches = {}
        match_start_us = minetest.get_us_time()
        last_match_duration = nil -- don't show the previous match's stale duration during this one
        battletanks.match_generation = battletanks.match_generation + 1
        local this_generation = battletanks.match_generation

        battletanks.clear_stray_dynamic_powerups()
        battletanks.clear_all_recognizers()

        if timeout_job then
            timeout_job:cancel(); timeout_job = nil
        end
        if clock_tick_job then
            clock_tick_job:cancel(); clock_tick_job = nil
        end

        match_clock_tick(this_generation) -- starts the once-a-second live clock refresh for this match

        if S.match_max_duration then
            timeout_job = minetest.after(lobby_system.settings.countdown_seconds + S.match_max_duration, function()
                if lobby_system.state.phase == "playing" and battletanks.match_generation == this_generation then
                    battletanks.end_match_timeout()
                end
            end)
        end

        if S.point_powerups_enabled then
            battletanks.spawn_point_powerup_entities()
        end
        if S.boost_powerups_enabled then
            battletanks.start_boost_powerup_loop(this_generation)
        end
        if S.shield_powerups_enabled then
            battletanks.start_shield_powerup_loop(this_generation)
        end
        if S.laser_powerups_enabled then
            battletanks.start_laser_powerup_loop(this_generation)
        end
        if S.rocket_powerups_enabled then
            battletanks.start_rocket_powerup_loop(this_generation)
        end

        spawn_bots(count)
    end,

    on_racing_started = function()
        for _, player in ipairs(minetest.get_connected_players()) do
            battletanks.hud.set_battle_table_visible(player, true)
        end
    end,

    on_match_start = function(name, index, pos, yaw)
        if battletanks.is_build_mode_on(name) then
            battletanks.set_build_mode(name, false)
        end

        local color = S.colors[index]
        local player = minetest.get_player_by_name(name)

        local pdata = {
            color = color,
            alive = true,
            racing = true,
            yaw = yaw,
            boost = starting_value(S.boost_powerups_enabled, S.starting_boost),
            was_left = false,
            was_right = false,
            tank_obj = nil,
            turret_obj = nil,
            engine_pitch_state = nil, -- nil means "not currently playing the loop sound"
            laser = starting_value(S.laser_powerups_enabled, S.starting_laser),
            laser_cooldown_remaining = 0,
            shield = starting_value(S.shield_powerups_enabled, S.starting_shield),
            rocket = starting_value(S.rocket_powerups_enabled, S.starting_rocket),
            rocket_cooldown_remaining = 0,
            battle_rank = 0,
            battle_score = 0,
        }
        battletanks.players[name] = pdata
        alive_count = alive_count + 1

        if player then
            player:set_physics_override({ speed = 0, jump = 0, gravity = 0 })
            pdata.tank_obj = battletanks.spawn_tank(player, pdata, color, pos, yaw)
            battletanks.spawn_recognizer_if_enabled(name, pos)
            battletanks.hud.add_boost_bar(player)
            battletanks.hud.set_battle_table_visible(player, true)
            battletanks.hud.update_battle_table()
            if battletanks.boost_hidden then
                battletanks.hud.set_boost_visible(player, false)
            end
            battletanks.hud.update_laser(player, pdata.laser)
            battletanks.hud.update_shield(player, pdata.shield)
            battletanks.hud.update_rocket(player, pdata.rocket)
            battletanks.hud.update_boost_bar(player, pdata.boost)
        end

    end,

    on_match_end = function(name)
        local pdata = battletanks.players[name]
        local player = minetest.get_player_by_name(name)
        battletanks.sounds.stop_engine_loop(name)
        battletanks.despawn_tank(player, pdata)
        battletanks.despawn_recognizer_for(name)
        if player then
            battletanks.hud.remove_boost_bar(player)
        end
        battletanks.players[name] = nil
    end,

    on_racing_ended = function()
        battletanks.hud.update_battle_table()
    end,

    extra_formspec = function(name)
        local fs = {}
        local is_admin = minetest.check_player_privs(name, { lobby_admin = true })

        if is_admin then
            local can_rebuild = lobby_system.state.phase == "lobby"
            local can_reset = can_rebuild or lobby_system.state.phase == "ended"

            local discovered = battletanks.discover_maps()
            local map_names = {}
            local current_key = battletanks.current_map_key()
            local current_idx = 1
            for i, m in ipairs(discovered) do
                map_names[i] = minetest.formspec_escape(m.display_name)
                if m.key == current_key then current_idx = i end
            end
            if #map_names == 0 then
                table.insert(fs, "label[0.4,4.9;Map: (no valid .mts files found in schems/)]")
            else
                table.insert(fs, "label[0.4,4.95;Map:]")
                table.insert(fs, "dropdown[1.25,4.65;2.95,0.7;lc_map_select;" ..
                    table.concat(map_names, ",") .. ";" .. current_idx .. ";true]")
                table.insert(fs, "button[4.35,4.65;3.70,0.7;lc_load_map;" ..
                    (can_rebuild and "Load Map" or "Load (wait)") .. "]")
            end

            local battle_options = { 1, 3, 5, 7, 10, 15, 20 }
            local races_idx = 4 -- default: "7", if nothing below matches better
            for i, n in ipairs(battle_options) do
                if n == S.matches_per_session then races_idx = i; break end
            end
            table.insert(fs, "label[0.4,5.8;Battles per game:]")
            table.insert(fs, "dropdown[2.8,5.50;1.40,0.7;lc_battles_select;" ..
                table.concat(battle_options, ",") .. ";" .. races_idx .. ";true]")
            table.insert(fs, "button[4.35,5.5;3.75,0.7;lc_reset_game;" ..
                (can_reset and "Reset Game" or "Reset (wait for lobby)") .. "]")

            local points_label = S.point_powerups_enabled
                and "Point Powerups: ON" or "Point Powerups: off"
            local boost_label = S.boost_powerups_enabled
                and "Boost Powerups: ON" or "Boost Powerups: off"
            table.insert(fs, "button[0.4,6.4;3.75,0.8;lc_point_powerups_toggle;" ..
                minetest.formspec_escape(points_label) .. "]")
            table.insert(fs, "button[4.35,6.4;3.75,0.8;lc_boost_powerups_toggle;" ..
                minetest.formspec_escape(boost_label) .. "]")

            local shield_label = S.shield_powerups_enabled
                and "Shield Powerups: ON" or "Shield Powerups: off"
            local laser_label = S.laser_powerups_enabled
                and "Laser Powerups: ON" or "Laser Powerups: off"
            table.insert(fs, "button[0.4,7.3;3.75,0.8;lc_shield_powerups_toggle;" ..
                minetest.formspec_escape(shield_label) .. "]")
            table.insert(fs, "button[4.35,7.3;3.75,0.8;lc_laser_powerups_toggle;" ..
                minetest.formspec_escape(laser_label) .. "]")

            local rocket_label = S.rocket_powerups_enabled
                and "Rocket Powerups: ON" or "Rocket Powerups: off"
            local recognizers_label = S.recognizers_enabled
                and "Recognizers: ON" or "Recognizers: off"
            table.insert(fs, "button[0.4,8.2;3.75,0.8;lc_rocket_powerups_toggle;" ..
                minetest.formspec_escape(rocket_label) .. "]")
            table.insert(fs, "button[4.35,8.2;3.75,0.8;lc_recognizers_toggle;" ..
                minetest.formspec_escape(recognizers_label) .. "]")

            table.insert(fs, "label[0.4,9.45;Bots:]")
            table.insert(fs, "dropdown[1.25,9.15;1.5,0.7;lc_bot_count;0,1,2,3,4,5,6,7;" ..
                (S.bot_count + 1) .. ";true]")
            local behavior_options = { "random", "passive", "opportunistic", "aggressive" }
            local behavior_idx = 1
            for i, b in ipairs(behavior_options) do
                if b == S.bot_behavior then behavior_idx = i; break end
            end
            table.insert(fs, "label[3.0,9.45;Behavior:]")
            table.insert(fs, "dropdown[4.4,9.15;3.7,0.7;lc_bot_behavior;" ..
                table.concat(behavior_options, ",") .. ";" .. behavior_idx .. ";true]")
            table.insert(fs, "button[0.4,10.8;3.75,0.8;lc_build_mode;Enter Build Mode]")
            table.insert(fs, "button[4.35,10.8;3.75,0.8;lc_export_map;Save Map]")
        else
            local discovered = battletanks.discover_maps()
            local current_key = battletanks.current_map_key()
            local map_display = "(none)"
            for _, m in ipairs(discovered) do
                if m.key == current_key then
                    map_display = m.display_name
                    break
                end
            end
            table.insert(fs, "label[0.4,4.95;Map: " .. minetest.formspec_escape(map_display) .. "]")

            table.insert(fs, "label[0.4,5.75;Battles per game: " .. S.matches_per_session .. "]")

            table.insert(fs, "label[0.4,6.55;Point Powerups: "
                .. (S.point_powerups_enabled and "ON" or "off") .. "]")
            table.insert(fs, "label[4.35,6.55;Boost Powerups: "
                .. (S.boost_powerups_enabled and "ON" or "off") .. "]")

            table.insert(fs, "label[0.4,7.35;Shield Powerups: "
                .. (S.shield_powerups_enabled and "ON" or "off") .. "]")
            table.insert(fs, "label[4.35,7.35;Laser Powerups: "
                .. (S.laser_powerups_enabled and "ON" or "off") .. "]")

            table.insert(fs, "label[0.4,8.15;Rocket Powerups: "
                .. (S.rocket_powerups_enabled and "ON" or "off") .. "]")
            table.insert(fs, "label[4.35,8.15;Recognizers: "
                .. (S.recognizers_enabled and "ON" or "off") .. "]")

            table.insert(fs, "label[0.4,8.95;Bots: " .. S.bot_count .. "]")
            if S.bot_count > 0 then
                table.insert(fs, "label[3.0,8.95;Behavior: "
                    .. minetest.formspec_escape(S.bot_behavior) .. "]")
            end
        end

        return table.concat(fs, "")
    end,

    on_extra_fields = function(name, fields)
        local is_admin = minetest.check_player_privs(name, { lobby_admin = true })

        if fields.lc_load_map then
            if is_admin and lobby_system.state.phase == "lobby" then
                local idx = tonumber(fields.lc_map_select)
                local map = idx and battletanks.discover_maps()[idx]
                if map then
                    minetest.chat_send_all("[BattleTanks] " .. name .. " is loading map: " .. map.display_name .. "...")
                    battletanks.load_map(map.key, function(ok)
                        minetest.chat_send_all(ok
                            and ("[BattleTanks] Map loaded: " .. map.display_name)
                            or ("[BattleTanks] Failed to load map: " .. map.display_name .. " - see server log."))
                        lobby_system.gui.refresh_all()
                    end)
                end
            end
            return true
        elseif fields.lc_export_map then
            if is_admin then
                battletanks.show_export_map(name)
            end
            return false
        elseif fields.lc_build_mode then
            if is_admin then
                battletanks.set_build_mode(name, true)
                minetest.chat_send_player(name, "[BattleTanks] Build mode ON - fly/noclip/give granted. "
                    .. "Bring the lobby panel back up (however you normally do) to leave build mode.")
                lobby_system.gui.close(name)
            end
            return false
        elseif fields.lc_point_powerups_toggle then
            if is_admin then
                S.point_powerups_enabled = not S.point_powerups_enabled
                if not S.point_powerups_enabled then
                    battletanks.despawn_point_powerup_entities()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned point powerups "
                    .. (S.point_powerups_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_boost_powerups_toggle then
            if is_admin then
                S.boost_powerups_enabled = not S.boost_powerups_enabled
                if not S.boost_powerups_enabled then
                    battletanks.clear_active_boost_powerup()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned boost powerups "
                    .. (S.boost_powerups_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_shield_powerups_toggle then
            if is_admin then
                S.shield_powerups_enabled = not S.shield_powerups_enabled
                if not S.shield_powerups_enabled then
                    battletanks.clear_active_shield_powerup()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned shield powerups "
                    .. (S.shield_powerups_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_laser_powerups_toggle then
            if is_admin then
                S.laser_powerups_enabled = not S.laser_powerups_enabled
                if not S.laser_powerups_enabled then
                    battletanks.clear_active_laser_powerup()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned laser powerups "
                    .. (S.laser_powerups_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_rocket_powerups_toggle then
            if is_admin then
                S.rocket_powerups_enabled = not S.rocket_powerups_enabled
                if not S.rocket_powerups_enabled then
                    battletanks.clear_active_rocket_powerup()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned rocket powerups "
                    .. (S.rocket_powerups_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_recognizers_toggle then
            if is_admin then
                S.recognizers_enabled = not S.recognizers_enabled
                if not S.recognizers_enabled then
                    battletanks.clear_all_recognizers()
                end
                minetest.chat_send_all("[BattleTanks] " .. name .. " turned Recognizers "
                    .. (S.recognizers_enabled and "ON" or "off") .. ".")
                lobby_system.gui.refresh_all()
            end
            return true
        elseif fields.lc_reset_game then
            if is_admin then
                local phase = lobby_system.state.phase
                if phase == "lobby" or phase == "ended" then
                    lobby_system.setup_new_game()
                    lobby_system.hud.update_all_scoreboards()
                    minetest.chat_send_all("[BattleTanks] " .. name
                        .. " reset the game - scores and battle count are back to the start.")
                    lobby_system.gui.refresh_all()
                else
                    minetest.chat_send_player(name,
                        "[BattleTanks] Can't reset while a match is in progress - try again once it ends.")
                end
            end
            return true
        elseif fields.lc_bot_count then
            if is_admin then
                local new_count = tonumber(fields.lc_bot_count) - 1 -- dropdown index (1-8) -> count (0-7)
                if new_count and new_count >= 0 and new_count <= 7 then
                    S.bot_count = new_count
                    minetest.chat_send_all("[BattleTanks] " .. name .. " set bot count to "
                        .. S.bot_count .. " (takes effect next match).")
                    lobby_system.gui.refresh_all()
                end
            end
            return true
        elseif fields.lc_bot_behavior then
            if is_admin then
                local behavior_options = { "random", "passive", "opportunistic", "aggressive" }
                local idx = tonumber(fields.lc_bot_behavior)
                local b = idx and behavior_options[idx]
                if b then
                    S.bot_behavior = b
                    minetest.chat_send_all("[BattleTanks] " .. name .. " set bot behavior to "
                        .. b .. " (takes effect next match).")
                    lobby_system.gui.refresh_all()
                end
            end
            return true
        elseif fields.lc_battles_select then
            if is_admin then
                local battle_options = { 1, 3, 5, 7, 10, 15, 20 }
                local idx = tonumber(fields.lc_battles_select)
                local n = idx and battle_options[idx]
                if n then
                    S.matches_per_session = n
                    lobby_system.set_matches_per_game(n)
                    minetest.chat_send_all("[BattleTanks] " .. name .. " set battles per game to " .. n .. ".")
                    lobby_system.gui.refresh_all()
                end
            end
            return true
        end
        return false
    end,
})


lobby_system.set_joined_lobby_text(function(name, info)
    return name .. " joined the game (" .. info.count .. "/" .. info.max .. ")."
end)
lobby_system.set_left_lobby_text("%s left the lobby.")
lobby_system.set_joined_game_text(function(name)
    return name .. " jumped into the battle!"
end)
lobby_system.set_left_game_text("%s disconnected mid-battle!")

lobby_system.set_reset_score_on_join(true)

lobby_system.set_new_game_on_second_player(true)

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if battletanks.players[name] and battletanks.players[name].alive then
        battletanks.eliminate(name)
    end
    battletanks.players[name] = nil
end)
