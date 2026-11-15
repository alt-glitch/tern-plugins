--!strict
-- The `list` block: your open pull requests and the ones waiting on your review, read with
-- `gh search prs` and refreshed every two minutes, grouped by repository. Keys: README.md.

local ui = tern.ui

local POLL_MS = 2 * 60 * 1000
local GH_TIMEOUT_MS = 30 * 1000
local INSTALL_URL = "https://cli.github.com"
local LIMIT = 100
local FIELDS = "--json=number,title,url,repository,author,updatedAt,isDraft"

-- One `gh search prs` per tab, in tab order.
local TABS = {
	{ id = "mine", label = "Yours", empty = "You have no open pull requests.", search = "--author=@me" },
	{ id = "review", label = "Review requested", empty = "Nothing is waiting on your review.", search = "--review-requested=@me" },
}

-- `gh` by name first, then where package managers put it: a daemon started by launchd or
-- systemd often has a PATH without those directories.
local GH = { "gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/home/linuxbrew/.linuxbrew/bin/gh", "/usr/bin/gh" }

type Pr = {
	id: string,
	repo: string,
	number: number,
	title: string,
	author: string,
	url: string,
	updated: number,
	draft: boolean,
}

-- Why a list could not be loaded: `missing` (no gh), `auth` (gh is not signed in) or `failed`.
type Problem = { kind: string, text: string, detail: string? }

type State = {
	cx: BlockCx,
	-- Each tab's pull requests once its first search answered.
	lists: { [string]: { Pr } },
	tab: string,
	query: string,
	drafts: boolean,
	-- The selected pull request's id, kept across refreshes while it is still shown.
	cursor: string?,
	pending: number,
	fetched: number?,
	problem: Problem?,
	timer: TimerHandle?,
}

-- A pane id survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	-- A pending process keeps its callback until the 30-second timeout; it must not refill this run.
	state.pending = 0
	state.lists = {}
	state.problem = nil
end

-- Blocks have no close hook, so callbacks also retire a pane that disappeared.
local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

-- Seconds since the epoch of an ISO 8601 UTC time, by the days-from-civil algorithm: `os.time`
-- with a table reads local time.
local function epoch(iso: string): number?
	local y, m, d, hh, mm, ss = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not (y and m and d and hh and mm and ss) then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(m) :: number, tonumber(d) :: number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (if month > 2 then month - 3 else month + 9) + 2) // 5 + day - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	local days = era * 146097 + doe - 719468
	return days * 86400 + (tonumber(hh) :: number) * 3600 + (tonumber(mm) :: number) * 60 + (tonumber(ss) :: number)
end

local function age(t: number): string
	local s = math.max(0, os.time() - t)
	if s < 3600 then
		return math.max(1, s // 60) .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	end
	return s // 86400 .. "d"
end

local function first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

local function problem_of(result: ProcessResult): Problem
	if result.timed_out then
		return { kind = "failed", text = "gh did not answer within 30 seconds." }
	end
	local err = result.stderr
	if
		result.status == 4
		or string.find(err, "gh auth login", 1, true) ~= nil
		or string.find(err, "GH_TOKEN", 1, true) ~= nil
		or string.find(err, "HTTP 401", 1, true) ~= nil
	then
		return { kind = "auth", text = "The GitHub CLI is not signed in.", detail = first_lines(err, 3) }
	end
	return { kind = "failed", text = "gh exited with status " .. result.status .. ".", detail = first_lines(err, 8) }
end

-- The pull requests in `gh`'s JSON, or nil when it isn't the expected list.
local function parse(stdout: string): { Pr }?
	local ok, data = pcall(tern.json.decode, stdout)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local prs: { Pr } = {}
	for _, item in data do
		local repo = if type(item.repository) == "table" then item.repository.nameWithOwner else nil
		local number = tonumber(item.number)
		if type(repo) == "string" and number and type(item.url) == "string" then
			table.insert(prs, {
				id = repo .. "#" .. number,
				repo = repo,
				number = number,
				title = tostring(item.title or ""),
				author = if type(item.author) == "table" then tostring(item.author.login) else "?",
				url = item.url,
				updated = epoch(tostring(item.updatedAt or "")) or os.time(),
				draft = item.isDraft == true,
			})
		end
	end
	return prs
end

-- Starts `gh` with `args`, trying each place it may be installed; the last spawn error when none starts.
local function run_gh(args: { string }, done: (ProcessResult) -> ()): string?
	local last = "gh is not on this machine's PATH"
	for _, gh in GH do
		if gh == "gh" or tern.fs.exists(gh) then
			local argv: { string } = { gh }
			for _, a in args do
				table.insert(argv, a)
			end
			local opts: ProcessOptions = {
				timeout_ms = GH_TIMEOUT_MS,
				env = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", NO_COLOR = "1" },
			}
			local ok, err = pcall(function()
				tern.process.run(argv, opts, function(result: ProcessResult, _)
					done(result)
				end)
			end)
			if ok then
				return nil
			end
			last = tostring(err)
		end
	end
	return last
end

-- Runs every tab's search in the background; each answer re-renders the block.
local function refresh(state: State)
	if not alive(state) or state.pending > 0 then
		return
	end
	state.problem = nil
	for _, tab in TABS do
		state.pending += 1
		local spawn_error = run_gh({ "search", "prs", tab.search, "--state=open", "--limit=" .. LIMIT, FIELDS }, function(result)
			if not alive(state) or state.pending == 0 then
				return
			end
			state.pending -= 1
			local prs = if result.status == 0 then parse(result.stdout) else nil
			if prs then
				state.lists[tab.id] = prs
				state.fetched = os.time()
			elseif result.status ~= 0 then
				state.problem = problem_of(result)
			else
				state.problem = {
					kind = "failed",
					text = "gh printed something other than a list of pull requests.",
					detail = first_lines(result.stdout, 4),
				}
			end
			state.cx:render()
		end)
		if spawn_error then
			state.pending = 0
			state.problem = { kind = "missing", text = "Tern could not start the GitHub CLI.", detail = spawn_error }
			return
		end
	end
end

-- One pending timer per live run, canceled explicitly when it is replaced.
local function poll(state: State)
	if not alive(state) or state.timer then
		return
	end
	state.timer = tern.timer(POLL_MS, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		refresh(state)
		state.cx:render()
		poll(state)
	end)
end

-- Where the lowercase `query` first occurs in `text`, as the picker's UTF-16 range; nil when absent.
local function hit(text: string, query: string): { number }?
	if query == "" then
		return nil
	end
	local at = string.find(string.lower(text), query, 1, true)
	if not at then
		return nil
	end
	local from = utf8.len(string.sub(text, 1, at - 1)) or (at - 1)
	return { from, from + (utf8.len(query) or #query) }
end

type Shown = { items: { any }, order: { any }, ids: { string }, hits: { [string]: { { number } } } }

-- The current tab's rows after the draft and text filters, grouped by repository: the repository
-- with the most recent activity first, newest first within each.
local function shown(state: State): Shown
	local q = string.lower(state.query)
	local groups: { [string]: { Pr } } = {}
	local repos: { string } = {}
	local hits: { [string]: { { number } } } = {}
	local list: { Pr } = state.lists[state.tab] or {}
	for _, pr in list do
		local text = pr.repo .. " #" .. pr.number .. " " .. pr.title .. " @" .. pr.author
		if (state.drafts or not pr.draft) and (q == "" or string.find(string.lower(text), q, 1, true)) then
			if not groups[pr.repo] then
				groups[pr.repo] = {}
				table.insert(repos, pr.repo)
			end
			table.insert(groups[pr.repo], pr)
			local h = hit(pr.title, q)
			if h then
				hits[pr.id] = { h }
			end
		end
	end
	for _, repo in repos do
		table.sort(groups[repo], function(a, b)
			return a.updated > b.updated
		end)
	end
	table.sort(repos, function(a, b)
		return groups[a][1].updated > groups[b][1].updated
	end)

	local items: { any }, order: { any }, ids: { string } = {}, {}, {}
	for _, repo in repos do
		table.insert(order, { group = repo, label = repo, count = #groups[repo] })
		for _, pr in groups[repo] do
			local item: { [string]: any } = {
				id = pr.id,
				label = pr.title,
				detail = { ui.span("#" .. pr.number, "muted num") },
				facts = {
					author = if state.tab == "review" then { ui.span("@" .. pr.author, "muted") } else nil,
					age = age(pr.updated),
				},
				title = pr.url,
			}
			if state.tab == "review" then
				item.mark = { text = pr.author }
			else
				item.icon = "merge"
			end
			if pr.draft then
				item.badges = { { text = "draft", tone = "warning" } }
				item.tone = "muted"
			end
			table.insert(items, item)
			table.insert(order, pr.id)
			table.insert(ids, pr.id)
		end
	end
	return { items = items, order = order, ids = ids, hits = hits }
end

-- Keeps the cursor on a shown row: the same pull request when it is still there, else the first.
local function settle(state: State, ids: { string })
	if not table.find(ids, state.cursor :: any) then
		state.cursor = ids[1]
	end
end

local function move(state: State, by: number)
	local ids = shown(state).ids
	local at = table.find(ids, state.cursor :: any) or 1
	state.cursor = ids[math.clamp(at + by, 1, math.max(1, #ids))]
end

local function find(state: State, id: string?): Pr?
	local list: { Pr } = state.lists[state.tab] or {}
	for _, pr in list do
		if pr.id == id then
			return pr
		end
	end
	return nil
end

local function open_selected(state: State, cx: BlockCx)
	local pr = find(state, state.cursor)
	if pr then
		cx:open(pr.url)
	end
end

local function next_tab(state: State, by: number)
	for i, tab in TABS do
		if tab.id == state.tab then
			state.tab = TABS[(i - 1 + by) % #TABS + 1].id
			return
		end
	end
end

local function problem_message(problem: Problem): { any }
	local spans: { any } = { ui.span(problem.text .. " ", "strong") }
	if problem.kind == "missing" then
		table.insert(spans, ui.span("Install the GitHub CLI on the machine that runs your panes, then refresh."))
	elseif problem.kind == "auth" then
		table.insert(spans, ui.span("Run "))
		table.insert(spans, ui.span("gh auth login", "strong"))
		table.insert(spans, ui.span(" in a shell on this machine, then refresh."))
	else
		table.insert(spans, ui.span("Refresh to try again."))
	end
	return spans
end

-- The line above the action bar: freshness, or a refresh problem that kept the last list.
local function status_line(state: State): string?
	if state.problem and state.lists[state.tab] then
		return state.problem.text .. " Showing the last list."
	elseif state.pending > 0 and state.lists[state.tab] then
		return "Refreshing…"
	elseif state.fetched then
		return "Updated " .. os.date("%H:%M", state.fetched)
	end
	return nil
end

local function picker(state: State): Node
	local rows = shown(state)
	settle(state, rows.ids)
	local loaded = state.lists[state.tab] ~= nil
	local tabs = {}
	for _, tab in TABS do
		local list = state.lists[tab.id]
		table.insert(tabs, { id = tab.id, label = tab.label, count = if list then #list else nil })
	end
	local empty = "No pull requests."
	for _, tab in TABS do
		if tab.id == state.tab then
			empty = tab.empty
		end
	end
	local actions: { any } = {
		{ id = "drafts", label = "Drafts", keys = { "ctrl+d" }, on = state.drafts },
		-- `retry` is also the button the picker's error card offers.
		{ id = "retry", label = "Refresh", keys = { "ctrl+r" } },
	}
	if state.problem and state.problem.kind == "missing" then
		table.insert(actions, { id = "install", label = "Install gh" })
	end
	table.insert(actions, { id = "open", label = "Open", keys = { "enter" }, primary = true, disabled = state.cursor == nil })
	local props: { [string]: any } = {
		key = "picker",
		size = "screen",
		preview = "none",
		icon = "merge",
		noun = "pull requests",
		placeholder = "Filter by title, repository, number or author",
		query = state.query,
		tabs = tabs,
		tab = state.tab,
		items = rows.items,
		order = rows.order,
		hits = rows.hits,
		selected = state.cursor,
		columns = {
			{ id = "author", head = "", format = "dim", priority = 50 },
			{ id = "age", head = "", format = "elapsed", priority = 100 },
		},
		empty = { ui.span(empty, "muted") },
		actions = actions,
	}
	local status = status_line(state)
	if status then
		props.strip = { label = status, items = {} }
	end
	if not loaded and state.problem then
		props.state = "error"
		props.message = problem_message(state.problem)
	elseif not loaded then
		props.state = "loading"
	end
	return ui.node("picker", props)
end

local function act(state: State, name: string, cx: BlockCx)
	if name == "drafts" then
		state.drafts = not state.drafts
	elseif name == "retry" then
		refresh(state)
	elseif name == "close" then
		-- The head's `esc` button: the same as the Esc key.
		state.query = ""
	elseif name == "install" then
		cx:open(INSTALL_URL)
	elseif name == "open" then
		open_selected(state, cx)
	end
end

tern.block.define("list", {
	init = function(cx: BlockCx, _args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local was = if type(saved) == "table" then saved else {}
		local state: State = {
			cx = cx,
			lists = {},
			tab = if was.tab == "review" then "review" else "mine",
			query = "",
			drafts = was.drafts == true,
			cursor = nil,
			pending = 0,
			fetched = nil,
			problem = nil,
			timer = nil,
		}
		running[cx.pane] = state
		refresh(state)
		poll(state)
		return state
	end,

	title = function(state: State): string?
		local list = state.lists[state.tab]
		if list then
			-- A full page means `gh` stopped at the limit, not that there are exactly that many.
			return "Pull requests (" .. #list .. (if #list >= LIMIT then "+" else "") .. ")"
		end
		return "Pull requests"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		-- The picker is a sheet: in `layer` at size `screen` it fills the pane and scrolls its own rows,
		-- where `main` would grow it to its full height. A region draws its root's children, so each
		-- region root is a column.
		return { main = ui.col({}), layer = ui.col({ picker(state) }) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.meta or key.alt then
			return false
		end
		if key.ctrl then
			if key.name == "r" then
				refresh(state)
			elseif key.name == "d" then
				state.drafts = not state.drafts
			elseif key.name == "u" then
				state.query = ""
			else
				return false
			end
			return true
		end
		local name = key.name
		if name == "up" then
			move(state, -1)
		elseif name == "down" then
			move(state, 1)
		elseif name == "page_up" then
			move(state, -10)
		elseif name == "page_down" then
			move(state, 10)
		elseif name == "home" then
			move(state, -math.huge)
		elseif name == "end" then
			move(state, math.huge)
		elseif name == "enter" then
			open_selected(state, cx)
		elseif name == "tab" then
			next_tab(state, if key.shift then -1 else 1)
		elseif name == "escape" then
			if state.query == "" then
				return false
			end
			state.query = ""
		elseif name == "backspace" then
			if state.query == "" then
				return false
			end
			local cut = utf8.offset(state.query, -1) or #state.query
			state.query = string.sub(state.query, 1, cut - 1)
		elseif (name == "paste" or key.text) and key.text and key.text ~= "" then
			state.query ..= (string.gsub(key.text, "[\r\n]+", " "))
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and ev.act == "tab" and type(ev.value) == "string" then
			state.tab = ev.value
		elseif ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, cx)
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.cursor = ev.item
			if ev.ev == "activate" then
				open_selected(state, cx)
			end
		end
	end,

	save = function(state: State): any
		return { tab = state.tab, drafts = state.drafts }
	end,
})
