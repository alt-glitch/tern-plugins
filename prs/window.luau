--!strict
-- The window half: the palette row and chord that open the block, and the route that opens a
-- list file (`*.prs.json`) in it.

local KIND = "prs.list"

-- Where hermes-tern writes the list of pull requests a Hermes pane's session linked, by Tern pane id.
local function hermes_list(pane: number): string?
	local home = tern.getenv("HERMES_HOME") or ""
	if home == "" then
		local user = tern.getenv("HOME")
		if not user then
			return nil
		end
		home = user .. "/.hermes"
	end
	local path = home .. "/plugin-data/hermes-tern/panes/" .. pane .. ".prs.json"
	return if tern.fs.exists(path) then path else nil
end

local function open_list(cx: WindowCx)
	local focused = cx.session:focused()
	-- From a Hermes pane: a block for its session's pull requests, to its right.
	local list = if focused then hermes_list(focused) else nil
	if focused and list then
		cx:new_block(KIND, { list }, "beside", { target = focused, dir = "right", ratio = 0.45 })
		return
	end
	-- Anywhere else: the block already open in this window (each open block polls GitHub), else a new one.
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

-- `tern open --split right <file>.prs.json` from a program opens its list beside the program's pane.
tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if string.sub(req.path, -9) == ".prs.json" then
		return { block = KIND, args = { req.path } }
	end
	return nil
end)
