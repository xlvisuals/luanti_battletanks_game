
lobby_system.sounds = {}

local S = lobby_system.settings.sound
local lobby_handles = {}


function lobby_system.sounds.play_joined()
    minetest.sound_play("joined", { gain = S.joined_gain }, true)
end

function lobby_system.sounds.play_won()
    minetest.sound_play("won", { gain = S.won_gain }, true)
end

function lobby_system.sounds.play_eliminated(name)
    minetest.sound_play("eliminated", { to_player = name, gain = S.eliminated_gain }, true)
end


function lobby_system.sounds.start_lobby_loop(player)
    local name = player:get_player_name()
    if lobby_handles[name] then return end
    lobby_handles[name] = minetest.sound_play("lobby_loop", {
        to_player = name, gain = S.lobby_gain, loop = true,
    })
end

function lobby_system.sounds.stop_lobby_loop(name)
    if lobby_handles[name] then
        minetest.sound_stop(lobby_handles[name])
        lobby_handles[name] = nil
    end
end

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if lobby_handles[name] then
        minetest.sound_stop(lobby_handles[name])
        lobby_handles[name] = nil
    end
end)
