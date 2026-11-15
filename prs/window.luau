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

-- The block this window opened for each list file, so opening the file again focuses that block
-- (which re-reads the file and opens its newly selected pull request) instead of adding another.
local opened: { [string]: number } = {}

-- Focuses the block showing list file `path`, or opens one to the right of `target`; its pane.
local function show_list(cx: WindowCx, path: string, target: number?): number?
	local pane = opened[path]
	for _, p in cx.session:panes() do
		if pane and p.pane == pane and p.block == KIND and not p.parked then
			cx.layout:focus(pane)
			return pane
		end
	end
	local new = cx:new_block(KIND, { path }, "beside", { target = target, dir = "right", ratio = 0.45 })
	if new then
		opened[path] = new
	end
	return new
end

local function open_list(cx: WindowCx)
	local focused = cx.session:focused()
	-- From a Hermes pane: a block for its session's pull requests, to its right.
	local list = if focused then hermes_list(focused) else nil
	if focused and list then
		show_list(cx, list, focused)
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

-- `tern open <file>.prs.json` from a program shows its list to the right of the focused pane (the
-- program's, when it asked from a click there), once per file.
tern.route.open(function(req: OpenRequest, cx: WindowCx): RouteDecision?
	if string.sub(req.path, -9) ~= ".prs.json" then
		return nil
	end
	if show_list(cx, req.path, cx.session:focused()) then
		return { handled = true }
	end
	return { block = KIND, args = { req.path } }
end)
