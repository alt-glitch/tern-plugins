--!strict
-- The `list` block: pull requests in lists (yours, waiting on your review, and a list file's, such
-- as a Hermes session's), and one pull request's page when you pick it. Keys: README.md.

local detail = require("./lib/detail")
local gh = require("./lib/gh")
local pr = require("./lib/pr")
local util = require("./lib/util")

local ui = tern.ui

local POLL_MS = 2 * 60 * 1000
-- A list file is local and small: read it often, so a link made in the session shows within seconds.
local WATCH_MS = 3 * 1000
local INSTALL_URL = "https://cli.github.com"
local LIMIT = 100
local FIELDS = "--json=number,title,url,repository,author,updatedAt,isDraft"

type Tab = { id: string, label: string, empty: string, search: string? }

-- The searches, in tab order. A list file adds its own tab in front.
local SEARCHES: { Tab } = {
	{ id = "mine", label = "Yours", empty = "You have no open pull requests.", search = "--author=@me" },
	{ id = "review", label = "Review requested", empty = "Nothing is waiting on your review.", search = "--review-requested=@me" },
}

type Row = {
	id: string,
	repo: string,
	number: number,
	title: string,
	author: string,
	url: string,
	updated: number,
	draft: boolean,
	state: string, -- open | merged | closed
}

-- A list file (`*.prs.json`): pull requests some program picked, such as the ones a Hermes
-- session linked. See README.md for the format.
type ListFile = { path: string, text: string, title: string, refs: { pr.Ref }, selected: string?, opened_at: number? }

type State = {
	cx: BlockCx,
	lists: { [string]: { Row } },
	file: ListFile?,
	tab: string,
	query: string,
	drafts: boolean,
	cursor: string?,
	pending: number,
	fetched: number?,
	problem: gh.Problem?,
	timer: TimerHandle?,
	watch: TimerHandle?,
	-- The pull request page, while one is open.
	page: detail.Detail?,
	prefs: detail.Prefs,
}

-- A pane id survives Restart; the state object identifies this block run.
local running: { [number]: State } = {}

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	for _, t in { state.timer, state.watch } do
		if t then
			t:cancel()
		end
	end
	state.timer, state.watch = nil, nil
	-- A pending process keeps its callback until its timeout; it must not refill this run.
	state.pending = 0
	state.lists = {}
	state.problem = nil
	state.page = nil
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

local function render(state: State)
	if alive(state) then
		state.cx:render()
	end
end

local function tabs(state: State): { Tab }
	local out: { Tab } = {}
	if state.file then
		table.insert(out, { id = "file", label = state.file.title, empty = "No pull requests linked yet." })
	end
	for _, t in SEARCHES do
		table.insert(out, t)
	end
	return out
end

-- ── Loading ───────────────────────────────────────────────────────────────────────────────────

local function parse_search(value: any): { Row }?
	if type(value) ~= "table" then
		return nil
	end
	local rows: { Row } = {}
	for _, item in value do
		local repo = util.str(util.obj(util.obj(item).repository).nameWithOwner)
		local number = util.obj(item).number
		if repo ~= "" and type(number) == "number" and type(item.url) == "string" then
			table.insert(rows, {
				id = repo .. "#" .. number,
				repo = repo,
				number = number,
				title = util.str(item.title),
				author = util.login(item.author),
				url = item.url,
				updated = util.epoch(item.updatedAt) or os.time(),
				draft = item.isDraft == true,
				state = "open",
			})
		end
	end
	return rows
end

-- The list file's pull requests, with titles and states from one GraphQL query.
local function load_file(state: State)
	local file = state.file
	if not file then
		return
	end
	state.pending += 1
	pr.summaries(file.refs, function(facts, problem)
		if not alive(state) or state.pending == 0 then
			return
		end
		state.pending -= 1
		if problem then
			state.problem = problem
		end
		local rows: { Row } = {}
		for _, ref in file.refs do
			local f = if facts then facts[pr.key(ref)] else nil
			local p: { [string]: any } = f or {}
			table.insert(rows, {
				id = pr.key(ref),
				repo = ref.repo,
				number = ref.number,
				title = if f then util.str(p.title) else ref.url,
				author = util.login(p.author),
				url = ref.url,
				updated = util.epoch(p.updatedAt) or 0,
				draft = p.isDraft == true,
				state = if p.state == "MERGED" then "merged" elseif p.state == "CLOSED" then "closed" else "open",
			})
		end
		state.lists.file = rows
		state.fetched = os.time()
		render(state)
	end)
end

-- Runs every list's query in the background; each answer re-renders the block.
local function refresh(state: State)
	if not alive(state) or state.pending > 0 then
		return
	end
	state.problem = nil
	load_file(state)
	for _, tab in SEARCHES do
		state.pending += 1
		gh.json({ "search", "prs", tab.search :: string, "--state=open", "--limit=" .. LIMIT, FIELDS }, function(value, problem)
			if not alive(state) or state.pending == 0 then
				return
			end
			state.pending -= 1
			local rows = parse_search(value)
			if rows then
				state.lists[tab.id] = rows
				state.fetched = os.time()
			else
				state.problem = problem or { kind = "failed", text = "gh printed something other than a list of pull requests." }
			end
			render(state)
		end)
	end
end

-- A list file's contents; nil when it cannot be read or is not version 1.
local function read_file(path: string): ListFile?
	local ok, text = pcall(tern.fs.read, path, 256 * 1024)
	if not ok then
		return nil
	end
	local decoded, data = pcall(tern.json.decode, text)
	if not decoded or type(data) ~= "table" or data.version ~= 1 then
		return nil
	end
	local refs: { pr.Ref } = {}
	local seen: { [string]: boolean } = {}
	if type(data.prs) == "table" then
		for _, p in data.prs do
			local item = util.obj(p)
			local ref = pr.ref(if type(item.url) == "string" then item.url else nil, util.str(item.repository), util.num(item.number))
			if ref and not seen[pr.key(ref)] then
				seen[pr.key(ref)] = true
				table.insert(refs, ref)
			end
		end
	end
	local title = util.str(data.title)
	return {
		path = path,
		text = text,
		title = if title ~= "" then title else "This session",
		refs = refs,
		selected = if util.str(data.selected) ~= "" then string.lower(util.str(data.selected)) else nil,
		opened_at = if type(data.opened_at) == "number" then data.opened_at else nil,
	}
end

local function open_page(state: State, ref: pr.Ref, seed: { title: string, author: string }?)
	local page = detail.new(ref, state.prefs, seed)
	state.page = page
	detail.load(page, function()
		render(state)
	end)
end

-- Re-reads the list file; a change reloads its list, and a new `selected` (or the same one picked
-- again, with a new `opened_at`) opens that pull request.
local function watch(state: State)
	if not alive(state) or state.watch or not state.file then
		return
	end
	state.watch = tern.timer(WATCH_MS, function()
		if not alive(state) then
			return
		end
		state.watch = nil
		local old = state.file
		local new = if old then read_file(old.path) else nil
		if old and new and new.text ~= old.text then
			state.file = new
			if new.selected and (new.selected ~= old.selected or new.opened_at ~= old.opened_at) then
				for _, ref in new.refs do
					if pr.key(ref) == new.selected then
						state.tab = "file"
						state.cursor = pr.key(ref)
						open_page(state, ref)
					end
				end
			end
			state.pending = 0
			load_file(state)
			render(state)
		end
		watch(state)
	end)
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
		render(state)
		poll(state)
	end)
end

-- ── The list ──────────────────────────────────────────────────────────────────────────────────

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

local STATE_WORD = { merged = { "merged", "accent" }, closed = { "closed", "error" } }

-- The current tab's rows after the draft and text filters, grouped by repository: the repository
-- with the most recent activity first, newest first within each.
local function shown(state: State): Shown
	local q = string.lower(state.query)
	local groups: { [string]: { Row } } = {}
	local repos: { string } = {}
	local hits: { [string]: { { number } } } = {}
	local list: { Row } = state.lists[state.tab] or {}
	-- A list file's pull requests are few and chosen: drafts always show there.
	local drafts = state.drafts or state.tab == "file"
	for _, row in list do
		local text = row.repo .. " #" .. row.number .. " " .. row.title .. " @" .. row.author
		if (drafts or not row.draft) and (q == "" or string.find(string.lower(text), q, 1, true)) then
			if not groups[row.repo] then
				groups[row.repo] = {}
				table.insert(repos, row.repo)
			end
			table.insert(groups[row.repo], row)
			local h = hit(row.title, q)
			if h then
				hits[row.id] = { h }
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
	local others = state.tab ~= "mine"
	for _, repo in repos do
		table.insert(order, { group = repo, label = repo, count = #groups[repo] })
		for _, row in groups[repo] do
			local item: { [string]: any } = {
				id = row.id,
				label = row.title,
				detail = { ui.span("#" .. row.number, "muted num") },
				facts = {
					author = if others then { ui.span("@" .. row.author, "muted") } else nil,
					state = if STATE_WORD[row.state] then { ui.span(STATE_WORD[row.state][1], STATE_WORD[row.state][2]) } else nil,
					age = if row.updated > 0 then util.age(row.updated) else nil,
				},
				title = row.url,
			}
			if others then
				item.mark = { text = row.author }
			else
				item.icon = "merge"
			end
			if row.draft then
				item.badges = { { text = "draft", tone = "warning" } }
				item.tone = "muted"
			end
			table.insert(items, item)
			table.insert(order, row.id)
			table.insert(ids, row.id)
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

local function find(state: State, id: string?): Row?
	local rows: { Row } = state.lists[state.tab] or {}
	for _, row in rows do
		if row.id == id then
			return row
		end
	end
	return nil
end

local function open_selected(state: State)
	local row = find(state, state.cursor)
	local ref = if row then pr.ref(row.url, row.repo, row.number) else nil
	if row and ref then
		-- The row's title and author draw at once; the rest follows when GitHub answers.
		open_page(state, ref, if row.title ~= row.url then { title = row.title, author = row.author } else nil)
	end
end

-- From a pull request page, the previous or next one in the list it came from (`[` and `]`).
local function step(state: State, by: number)
	local ids = shown(state).ids
	if #ids == 0 then
		return
	end
	local at = table.find(ids, state.cursor :: any) or 1
	state.cursor = ids[(at - 1 + by) % #ids + 1]
	open_selected(state)
end

local function next_tab(state: State, by: number)
	local all = tabs(state)
	for i, tab in all do
		if tab.id == state.tab then
			state.tab = all[(i - 1 + by) % #all + 1].id
			return
		end
	end
	state.tab = all[1].id
end

local function problem_message(problem: gh.Problem): { any }
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
	local strip_tabs = {}
	local empty = "No pull requests."
	for _, tab in tabs(state) do
		local list = state.lists[tab.id]
		table.insert(strip_tabs, { id = tab.id, label = tab.label, count = if list then #list else nil })
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
	table.insert(actions, { id = "github", label = "GitHub", keys = { "ctrl+o" }, ["end"] = true, disabled = state.cursor == nil })
	table.insert(actions, { id = "open", label = "Open", keys = { "enter" }, primary = true, disabled = state.cursor == nil })
	local props: { [string]: any } = {
		key = "picker",
		size = "screen",
		preview = "none",
		icon = "merge",
		noun = "pull requests",
		placeholder = "Filter by title, repository, number or author",
		query = state.query,
		tabs = strip_tabs,
		tab = state.tab,
		items = rows.items,
		order = rows.order,
		hits = rows.hits,
		selected = state.cursor,
		columns = {
			{ id = "author", head = "", format = "dim", priority = 50 },
			{ id = "state", head = "", format = "text", priority = 90 },
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

local function list_action(state: State, name: string, cx: BlockCx)
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
		open_selected(state)
	elseif name == "github" then
		local row = find(state, state.cursor)
		if row then
			cx:open(row.url)
		end
	end
end

local function list_key(state: State, key: Key, cx: BlockCx): boolean
	if key.ctrl then
		if key.name == "r" then
			refresh(state)
		elseif key.name == "d" then
			state.drafts = not state.drafts
		elseif key.name == "u" then
			state.query = ""
		elseif key.name == "o" then
			list_action(state, "github", cx)
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
		open_selected(state)
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
end

-- ── The block ─────────────────────────────────────────────────────────────────────────────────

tern.block.define("list", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local was = if type(saved) == "table" then saved else {}
		local file = if args and type(args[1]) == "string" then read_file(args[1]) else nil
		local state: State = {
			cx = cx,
			lists = {},
			file = file,
			tab = if file then "file" elseif was.tab == "review" then "review" else "mine",
			query = "",
			drafts = was.drafts == true,
			cursor = nil,
			pending = 0,
			fetched = nil,
			problem = nil,
			timer = nil,
			watch = nil,
			page = nil,
			prefs = detail.prefs(was.prefs),
		}
		running[cx.pane] = state
		refresh(state)
		poll(state)
		watch(state)
		-- Opened for one pull request (a list file's `selected`, or a page open before a restart).
		local open = if file and file.selected then file.selected else if type(was.page) == "string" then was.page else nil
		if open then
			local repo, n = string.match(open, "^([^#]+)#(%d+)$")
			local ref = pr.ref(nil, repo, tonumber(n))
			if ref then
				state.cursor = pr.key(ref)
				open_page(state, ref)
			end
		end
		return state
	end,

	title = function(state: State): string?
		local page = state.page
		if page then
			return "#" .. page.ref.number .. (if page.pr then " " .. page.pr.title else "")
		end
		local list = state.lists[state.tab]
		if list then
			-- A full page means `gh` stopped at the limit, not that there are exactly that many.
			return "Pull requests (" .. #list .. (if #list >= LIMIT and state.tab ~= "file" then "+" else "") .. ")"
		end
		return "Pull requests"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		local page = state.page
		if page then
			-- The page scrolls with the pane; its actions stay in the dock under it.
			local dock = detail.dock(page)
			return { main = ui.col({ detail.main(page) }), dock = if dock then ui.col({ dock }) else nil }
		end
		-- The picker is a sheet: in `layer` at size `screen` it fills the pane and scrolls its own rows,
		-- where `main` would grow it to its full height. A region draws its root's children, so each
		-- region root is a column.
		return { main = ui.col({}), layer = ui.col({ picker(state) }) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.meta or key.alt then
			return false
		end
		local page = state.page
		if page then
			local bare = not key.ctrl
			local modal = detail.modal(page)
			if not modal and (key.name == "escape" or key.name == "backspace" or (bare and key.name == "left")) then
				state.page = nil
				return true
			elseif not modal and bare and (key.name == "[" or key.name == "]") then
				step(state, if key.name == "]" then 1 else -1)
				return true
			end
			return detail.key(page, key, cx, function()
				render(state)
			end)
		end
		return list_key(state, key, cx)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		local page = state.page
		if page then
			if ev.ev == "action" and ev.act == "back" then
				state.page = nil
			else
				detail.event(page, ev, cx, function()
					render(state)
				end)
			end
			return
		end
		if ev.ev == "action" and ev.act == "tab" and type(ev.value) == "string" then
			state.tab = ev.value
		elseif ev.ev == "action" and type(ev.act) == "string" then
			list_action(state, ev.act, cx)
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			state.cursor = ev.item
			if ev.ev == "activate" then
				open_selected(state)
			end
		end
	end,

	save = function(state: State): any
		return {
			tab = if state.tab == "file" then nil else state.tab,
			drafts = state.drafts,
			page = if state.page then pr.key(state.page.ref) else nil,
			prefs = state.prefs,
		}
	end,
})
