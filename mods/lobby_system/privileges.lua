
minetest.register_privilege("lobby_admin", {
    description = "Can start a match below the usual minimum player count, and use "
        .. "other admin-only lobby actions",
    give_to_singleplayer = true,
    give_to_admin = true,
})
