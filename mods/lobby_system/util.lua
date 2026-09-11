
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

function lobby_system.enter_idle_state(player)
    player:set_physics_override({
        speed = 0, jump = 0, gravity = 0, sneak = false, sneak_glitch = false,
    })
    lobby_system.hide_player_body(player)
    lobby_system.hide_nametag(player)
end
