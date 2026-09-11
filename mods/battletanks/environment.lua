minetest.register_on_mods_loaded(function()
    minetest.after(0, function()
        minetest.settings:set("time_speed", "0") -- stop the clock
        minetest.set_timeofday(battletanks.settings.night_time_of_day)
    end)
end)

minetest.register_on_joinplayer(function(player)
    player:set_clouds({ density = 0 })

    local flags = player:hud_get_flags()
    flags.wielditem = false
    flags.crosshair = false
    player:hud_set_flags(flags)

    player:set_sky({
        type = "plain",
        base_color = battletanks.settings.sky_color,
        clouds = false,
    })
    player:set_sun({ visible = false, sunrise_visible = false })
    player:set_moon({ visible = false })
    player:set_stars({ visible = false })
end)
