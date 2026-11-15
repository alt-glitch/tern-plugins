--!strict
-- The window half: the palette row and chord that open the list beside the focused pane, or focus
-- the one already open in this window (each open list polls GitHub).

local KIND = "prs.list"

local function open_list(cx: WindowCx)
	for _, pane in cx.session:panes() do
		if pane.block == KIND and not pane.parked then
			cx.layout:focus(pane.pane)
			return
		end
	end
	if cx:new_block(KIND, nil, "beside", { dir = "right", ratio = 0.45 }) == nil then
		cx:toast("error", "Pull requests is not loaded on this host", "Install the plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Pull requests",
	icon = "merge",
	keys = { "alt+shift+cmd+p" },
	run = open_list,
})
