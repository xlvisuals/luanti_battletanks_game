
function lobby_system.hide_player_body(player)
    player:set_properties({ visual_size = { x = 0, y = 0, z = 0 } })
end

function lobby_system.hide_nametag(player)
    player:set_nametag_attributes({
        text = "",
        color = { r = 255, g = 255, b = 255, a = 0 },
        bgcolor = { r = 0, g = 0, b = 0, a = 0 },
    })
end

function lobby_system.show_nametag(player, text)
    player:set_nametag_attributes({
        text = text or player:get_player_name(),
        color = { r = 255, g = 255, b = 255, a = 255 },
        bgcolor = false,
    })
end

-- Privileges granted only while idle (connected but not currently
-- racing - waiting in the lobby, or just observing) so they can move
-- freely and watch a match in progress instead of being frozen in place.
-- Always revoked again the moment a player actually starts racing (see
-- exit_idle_state below, called from lobby.lua's start_one_player) -
-- this happens automatically for every game built on lobby_system, not
-- just battletanks, so there's no risk of a racer keeping noclip/fly
-- into an actual match.
local IDLE_FLY_PRIVS = { fly = true, fast = true, noclip = true }

function lobby_system.enter_idle_state(player)
    player:set_physics_override({
        speed = 1, jump = 1, gravity = 0, sneak = false, sneak_glitch = false,
    })
    local name = player:get_player_name()
    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(IDLE_FLY_PRIVS) do
        privs[priv] = true
    end
    minetest.set_player_privs(name, privs)
    lobby_system.hide_player_body(player)
    lobby_system.hide_nametag(player)
end

function lobby_system.exit_idle_state(player)
    local name = player:get_player_name()
    local privs = minetest.get_player_privs(name)
    for priv, _ in pairs(IDLE_FLY_PRIVS) do
        privs[priv] = nil
    end
    minetest.set_player_privs(name, privs)
end
