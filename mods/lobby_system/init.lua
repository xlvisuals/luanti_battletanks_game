
local modpath = minetest.get_modpath("lobby_system")

dofile(modpath .. "/settings.lua")
dofile(modpath .. "/privileges.lua")
dofile(modpath .. "/util.lua")
dofile(modpath .. "/hud.lua")
dofile(modpath .. "/sounds.lua")
dofile(modpath .. "/gui.lua")
dofile(modpath .. "/lobby.lua")

minetest.log("action", "[lobby_system] mod loaded")
