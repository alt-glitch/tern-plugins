--!strict
-- One pull request in the block: a header (repository and number, state, title, author, branches,
-- size, reviewers, checks), then three tabs, as GitHub's and T3 Code's PR pages show them:
-- Conversation (the description and every comment, review, review thread and commit in order),
-- Checks (grouped, failures first) and Files (each file as Tern's edit card with its diff).
-- The actions sit in the dock, which also asks before a merge or close.

local gh = require("./gh")
local pr = require("./pr")
local util = require("./util")

local ui = tern.ui

local M = {}

export type Detail = {
	ref: pr.Ref,
	pr: pr.Pr?,
	problem: gh.Problem?,
	loading: boolean,
	tab: string, -- conversation | checks | files
	activity: { pr.Activity }?,
	activity_problem: gh.Problem?,
	files: { pr.File }?,
	files_problem: gh.Problem?,
	confirm: string?, -- merge | close
	busy: string?, -- the action running now
	-- Bumped on every load, so an answer for an older load or another PR is dropped.
	generation: number,
}

local TABS = { "conversation", "checks", "files" }
local LONG_DIFF = 400

local METHOD_LABEL = { merge = "Merge", squash = "Squash and merge", rebase = "Rebase and merge" }
local DECISION = {
	APPROVED = { "Approved", "success" },
	CHANGES_REQUESTED = { "Changes requested", "error" },
	REVIEW_REQUIRED = { "Review required", "warning" },
}
local REVIEW_VERB = {
	APPROVED = { "approved these changes", "success" },
	CHANGES_REQUESTED = { "requested changes", "error" },
	COMMENTED = { "reviewed", "muted" },
	DISMISSED = { "reviewed (dismissed)", "muted" },
	PENDING = { "started a review", "muted" },
}
local CHECK = {
	["action-required"] = { "pending", "warning", "waiting for approval" },
	cancelled = { "cancelled", "muted", "cancelled" },
	failure = { "failed", "error", "failed" },
	neutral = { "minus", "muted", "neutral" },
	pending = { "running", "warning", "running" },
	skipped = { "minus", "muted", "skipped" },
	success = { "success", "success", "passed" },
}
local FILE_TITLE = { added = "Added", copied = "Copied", modified = "Changed", removed = "Deleted", renamed = "Renamed" }

function M.new(ref: pr.Ref): Detail
	return {
		ref = ref,
		pr = nil,
		problem = nil,
		loading = false,
		tab = "conversation",
		activity = nil,
		activity_problem = nil,
		files = nil,
		files_problem = nil,
		confirm = nil,
		busy = nil,
		generation = 0,
	}
end

-- Reads what the current tab needs and has not read yet.
local function load_tab(d: Detail, render: () -> ())
	local gen = d.generation
	if d.tab == "conversation" and not d.activity and not d.activity_problem then
		pr.activity(d.ref, function(items, problem)
			if d.generation == gen then
				d.activity, d.activity_problem = items, problem
				render()
			end
		end)
	elseif d.tab == "files" and not d.files and not d.files_problem then
		pr.files(d.ref, function(files, problem)
			if d.generation == gen then
				d.files, d.files_problem = files, problem
				render()
			end
		end)
	end
end

-- Reads the PR, then the current tab; `render` runs after each answer.
function M.load(d: Detail, render: () -> ())
	d.generation += 1
	d.loading = true
	d.activity, d.activity_problem, d.files, d.files_problem = nil, nil, nil, nil
	local gen = d.generation
	pr.load(d.ref, function(p, problem)
		if d.generation ~= gen then
			return
		end
		d.loading = false
		if p then
			d.pr, d.problem = p, nil
		else
			d.problem = problem
		end
		render()
	end)
	load_tab(d, render)
end

function M.set_tab(d: Detail, tab: string, render: () -> ())
	d.tab = tab
	d.confirm = nil
	load_tab(d, render)
end

local function act(d: Detail, action: string, cx: BlockCx, render: () -> ())
	local p = d.pr
	d.confirm = nil
	if not p or d.busy or not pr.can(action, p) then
		return
	end
	d.busy = action
	pr.act(action, p, function(problem)
		d.busy = nil
		if problem then
			cx:toast("error", "Could not " .. action .. " #" .. p.number, problem.text)
		end
		M.load(d, render)
	end)
end

-- ── Drawing ───────────────────────────────────────────────────────────────────────────────────

local function clicky(node: Node, action: string): Node
	local props: { [string]: any } = node.p or {}
	props.actions = { click = action }
	node.p = props
	return node
end

local function keyed(node: Node, key: string): Node
	local props: { [string]: any } = node.p or {}
	props.key = key
	node.p = props
	return node
end

local function with(node: Node, extra: { [string]: any }): Node
	local props: { [string]: any } = node.p or {}
	for k, v in extra do
		props[k] = v
	end
	node.p = props
	return node
end

-- GitHub bodies hold HTML that Tern's Markdown would show as text: comments from PR templates,
-- and `<details>` folds, whose summary becomes a bold line.
local function markdown(body: string, key: string, empty: string?): Node
	local text = string.gsub(body, "<!%-%-.-%-%->", "")
	text = string.gsub(text, "<summary>%s*(.-)%s*</summary>", "**%1**")
	text = string.gsub(text, "</?details[^>]*>", "")
	if not string.match(text, "%S") then
		return keyed(ui.text({ ui.span(empty or "No description provided.", "muted") }), key)
	end
	return keyed(ui.md(text), key)
end

local function header(d: Detail): Node
	local p = d.pr
	local ref = d.ref
	local top: { Node } = {
		keyed(ui.text({ ui.link(ref.repo .. " #" .. ref.number, ref.url, "dim") }), "ref"),
	}
	if not p then
		local text = if d.problem then d.problem.text else "Reading GitHub…"
		return ui.col({
			keyed(ui.row(top), "top"),
			keyed(ui.text({ ui.span(text, if d.problem then "error" else "muted") }), "title"),
		})
	end
	local decision = DECISION[p.review_decision]
	if decision and p.state == "open" then
		table.insert(top, keyed(ui.badge(decision[1], decision[2]), "review"))
	end
	table.insert(top, keyed(ui.badge(pr.state_label(p), pr.state_tone(p)), "state"))

	local verb = if p.state == "merged" then "merged" elseif p.state == "closed" then "closed" else "opened"
	local when = if p.state == "merged" then p.merged elseif p.state == "closed" then p.closed else p.created
	local rows: { Node } = {
		keyed(with(ui.row(top), { gap = "sm", align = "center" }), "top"),
		keyed(ui.text({ ui.span(p.title, "strong") }), "title"),
		keyed(
			ui.text({
				ui.span(p.author, "strong"),
				ui.span(" " .. verb .. " " .. util.ago(when), "muted"),
				ui.span(" · updated " .. util.ago(p.updated), "dim"),
			}),
			"who"
		),
		keyed(
			ui.text({
				ui.span(p.base, "mono muted"),
				ui.span("  ←  ", "dim"),
				ui.span(p.head, "mono muted"),
				ui.span("    " .. util.plural(p.changed_files, "file") .. "  ", "muted"),
				ui.span("+" .. util.thousands(p.additions), "success"),
				ui.span(" "),
				ui.span("−" .. util.thousands(p.deletions), "error"),
			}),
			"branch"
		),
	}
	if #p.reviewers > 0 then
		local spans: { any } = { ui.span("Reviewers  ", "dim") }
		for i, r in p.reviewers do
			local tone = if r.state == "APPROVED"
				then "success"
				elseif r.state == "CHANGES_REQUESTED" then "error"
				elseif r.state == "PENDING" then "dim"
				else "muted"
			table.insert(spans, ui.span((if i > 1 then ", " else "") .. r.login, tone))
		end
		table.insert(rows, keyed(ui.text(spans), "reviewers"))
	end
	if #p.labels > 0 then
		local badges: { Node } = {}
		for i, l in p.labels do
			table.insert(badges, keyed(ui.badge(l, "neutral"), "l" .. i))
		end
		table.insert(rows, keyed(with(ui.row(badges), { gap = "xs", wrap = true }), "labels"))
	end
	return with(ui.col(rows), { gap = "sm" })
end

local function tab_bar(d: Detail): Node
	local p = d.pr
	local talk = 0
	local seen_activity: { pr.Activity } = d.activity or {}
	for _, a in seen_activity do
		if a.kind ~= "commit" then
			talk += 1
		end
	end
	local items = {
		{ id = "conversation", label = if talk > 0 then { ui.span("Conversation "), ui.span(tostring(talk), "muted") } else "Conversation" },
		{ id = "checks", label = if p and #p.checks > 0 then { ui.span("Checks "), ui.span(tostring(#p.checks), "muted") } else "Checks" },
		{ id = "files", label = if p then { ui.span("Files "), ui.span(tostring(p.changed_files), "muted") } else "Files" },
	}
	local children: { Node } = { ui.node("tabs", { key = "t", active = d.tab, items = items }) }
	if p then
		local tone = pr.checks_tone(p.checks)
		table.insert(children, ui.node("spacer", { key = "fill", grow = 1 }))
		table.insert(
			children,
			clicky(keyed(ui.text({ ui.span(if #p.checks > 0 then pr.checks_summary(p.checks) else "No checks reported", tone) }), "checks"), "tab=checks")
		)
	end
	return with(ui.row(children), { align = "center", gap = "sm" })
end

local function comment(key: string, who: { any }, at: number, body: string, url: string?, empty: string?): Node
	local head = table.clone(who)
	table.insert(head, ui.span(" · " .. util.age(at) .. " ago", "dim"))
	local children: { Node } = { markdown(body, "b", empty) }
	if url and url ~= "" then
		table.insert(children, keyed(ui.text({ ui.link("View on GitHub", url, "dim") }), "link"))
	end
	return keyed(ui.card(head, children), key)
end

local function conversation(d: Detail, p: pr.Pr): { Node }
	local out: { Node } = {
		comment("desc", { ui.span(p.author, "strong"), ui.span(" opened this", "muted") }, util.epoch(p.created) or 0, p.body, nil),
	}
	if not d.activity then
		local problem = d.activity_problem
		table.insert(out, keyed(ui.text({ ui.span(if problem then problem.text else "Reading the conversation…", if problem then "error" else "muted") }), "load"))
		return out
	end
	-- Runs of commits fold into one block each, as GitHub groups pushes.
	local run: { pr.Activity } = {}
	local function flush()
		if #run == 0 then
			return
		end
		local authors, seen = {}, {}
		for _, c in run do
			if not seen[c.author] then
				seen[c.author] = true
				table.insert(authors, c.author)
			end
		end
		local rows: { Node } = {}
		for i, c in run do
			local sha = if c.url then string.match(c.url, "/commit/(%x%x%x%x%x%x%x)") else nil
			local spans: { any } = { ui.span(c.body) }
			if sha and c.url then
				table.insert(spans, ui.span("  "))
				table.insert(spans, ui.link(sha, c.url, "mono dim"))
			end
			table.insert(rows, keyed(ui.text(spans), "c" .. i))
		end
		local last = run[#run]
		table.insert(
			out,
			keyed(
				with(ui.section({
					ui.span(table.concat(authors, ", "), "strong"),
					ui.span(" added " .. util.plural(#run, "commit"), "muted"),
					ui.span(" · " .. util.age(last.at) .. " ago", "dim"),
				}, rows), { collapsible = true, collapsed = #run > 3 }),
				"run" .. #out
			)
		)
		run = {}
	end
	for i, a in d.activity :: { pr.Activity } do
		if a.kind == "commit" then
			table.insert(run, a)
			continue
		end
		flush()
		local key = "a" .. i
		if a.kind == "review" then
			local verb = REVIEW_VERB[a.state or "COMMENTED"] or REVIEW_VERB.COMMENTED
			local who = { ui.span(a.author, "strong"), ui.span(" " .. verb[1], if verb[2] == "muted" then "muted" else verb[2]) }
			if string.match(a.body, "%S") then
				table.insert(out, comment(key, who, a.at, a.body, a.url))
			else
				table.insert(who, ui.span(" · " .. util.age(a.at) .. " ago", "dim"))
				table.insert(out, keyed(ui.text(who), key))
			end
		elseif a.kind == "thread" then
			local where = (a.path or "") .. (if a.line then ":" .. a.line else "")
			local head: { any } = {
				ui.span(a.author, "strong"),
				ui.span(" commented on ", "muted"),
				ui.span(where, "mono"),
				ui.span(" · " .. util.age(a.at) .. " ago", "dim"),
			}
			if a.resolved then
				table.insert(head, ui.span("  resolved", "success"))
			end
			if a.outdated then
				table.insert(head, ui.span("  outdated", "dim"))
			end
			local children: { Node } = { markdown(a.body, "b") }
			local replies: { { author: string, body: string, at: number } } = a.replies or {}
			for j, r in replies do
				table.insert(
					children,
					keyed(
						ui.col({
							keyed(ui.text({ ui.span(r.author, "strong"), ui.span(" · " .. util.age(r.at) .. " ago", "dim") }), "h"),
							markdown(r.body, "b"),
						}),
						"r" .. j
					)
				)
			end
			if a.url and a.url ~= "" then
				table.insert(children, keyed(ui.text({ ui.link("View on GitHub", a.url, "dim") }), "link"))
			end
			table.insert(out, keyed(with(ui.card(head, children), { collapsible = true, collapsed = a.resolved or a.outdated }), key))
		else
			table.insert(out, comment(key, { ui.span(a.author, "strong"), ui.span(" commented", "muted") }, a.at, a.body, a.url))
		end
	end
	flush()
	return out
end

local function checks(p: pr.Pr): { Node }
	if #p.checks == 0 then
		return { keyed(ui.text({ ui.span("No checks ran on the latest commit.", "muted") }), "none") }
	end
	local sorted = table.clone(p.checks)
	table.sort(sorted, function(a, b)
		return a.name < b.name
	end)
	local groups: { { id: string, head: string, open: boolean, test: { [string]: boolean } } } = {
		{ id = "bad", head = "Needs attention", open = true, test = { failure = true, cancelled = true, ["action-required"] = true } },
		{ id = "run", head = "Running", open = true, test = { pending = true } },
		{ id = "ok", head = "Passed", open = false, test = { success = true } },
		{ id = "skip", head = "Skipped", open = false, test = { skipped = true, neutral = true } },
	}
	local runs = #pr.failed_runs(p.checks)
	local out: { Node } = {
		keyed(
			ui.text({
				ui.span(pr.checks_summary(p.checks), pr.checks_tone(p.checks)),
				ui.span(" · on " .. string.sub(p.head_oid, 1, 7) .. (if runs > 0 then " · f re-runs " .. util.plural(runs, "failed workflow run") else ""), "dim"),
			}),
			"sum"
		),
	}
	local now = os.time()
	for _, g in groups do
		local rows: { Node } = {}
		for i, c in sorted do
			if g.test[c.status] then
				local look = CHECK[c.status] or CHECK.neutral
				local took = if c.started and c.completed
					then util.duration(c.completed - c.started)
					elseif c.started and c.status == "pending" then util.duration(now - c.started) .. "…"
					else ""
				local name = if c.url then ui.link(c.name, c.url) else ui.span(c.name)
				local spans: { any } = { name }
				if c.workflow and string.sub(c.name, 1, #c.workflow + 2) ~= c.workflow .. " /" then
					table.insert(spans, ui.span("  " .. c.workflow, "dim"))
				end
				table.insert(spans, ui.span("  " .. look[3], if look[2] == "muted" then "dim" else look[2]))
				if took ~= "" then
					table.insert(spans, ui.span("  " .. took, "dim mono"))
				end
				local row = with(ui.row({ keyed(ui.node("icon", { name = look[1], tone = look[2] }), "i"), keyed(ui.text(spans), "t") }), {
					align = "center",
					gap = "sm",
					title = c.description,
				})
				table.insert(rows, keyed(row, "k" .. i))
			end
		end
		if #rows > 0 then
			table.insert(out, keyed(with(ui.section(g.head .. " · " .. #rows, rows), { collapsible = true, collapsed = not g.open }), g.id))
		end
	end
	return out
end

local function files(d: Detail, p: pr.Pr): { Node }
	if not d.files then
		local problem = d.files_problem
		return { keyed(ui.text({ ui.span(if problem then problem.text else "Reading the files…", if problem then "error" else "muted") }), "load") }
	end
	local list = d.files :: { pr.File }
	if #list == 0 then
		return { keyed(ui.text({ ui.span("No files changed.", "muted") }), "none") }
	end
	local out: { Node } = {}
	for i, f in list do
		local lines = 0
		if f.patch then
			for _ in string.gmatch(f.patch, "\n") do
				lines += 1
			end
		end
		local body: { Node } = if f.patch
			then { keyed(ui.diff(f.patch, f.path), "d") }
			else { keyed(ui.text({ ui.span("Binary, or too large to show here.", "muted") }), "none") }
		table.insert(
			out,
			ui.node("tool", {
				key = "f" .. i,
				name = if f.status == "added" then "write" else "edit",
				status = "done",
				title = FILE_TITLE[f.status] or "Changed",
				target = f.path,
				targetKind = "path",
				meta = { "+" .. f.additions .. " −" .. f.deletions },
				badges = if f.previous then { { text = "from " .. f.previous } } else nil,
				collapsible = true,
				collapsed = f.status == "removed" or lines > LONG_DIFF,
			}, body)
		)
	end
	if #list < p.changed_files then
		table.insert(out, keyed(ui.text({ ui.link(p.changed_files - #list .. " more on GitHub", p.url .. "/files", "muted") }), "more"))
	end
	return out
end

function M.main(d: Detail): Node
	local children: { Node } = {
		keyed(ui.text({ ui.span("← ", "dim"), ui.span("Pull requests", "dim") }), "back"),
		keyed(header(d), "head"),
	}
	children[1] = clicky(children[1], "back")
	local p = d.pr
	if p then
		table.insert(children, keyed(tab_bar(d), "tabs"))
		local body = if d.tab == "checks" then checks(p) elseif d.tab == "files" then files(d, p) else conversation(d, p)
		table.insert(children, keyed(with(ui.col(body), { gap = "md" }), "body-" .. d.tab))
	end
	return with(ui.col(children), { gap = "md" })
end

local function button(label: string, action: string, keys: { string }?, variant: string?, disabled: boolean?): Node
	return clicky(ui.button(label, { keys = keys, variant = variant :: any, disabled = disabled, size = "sm" }), "do=" .. action)
end

function M.dock(d: Detail): Node?
	local p = d.pr
	if not p then
		return nil
	end
	local method = p.methods[1] or "merge"
	if d.confirm then
		local merge = d.confirm == "merge"
		local question = if merge
			then { ui.span((METHOD_LABEL[method] or "Merge") .. " #" .. p.number .. " into "), ui.span(p.base, "mono"), ui.span("?") }
			else { ui.span("Close #" .. p.number .. " without merging?") }
		return with(
			ui.row({
				keyed(ui.text(question), "q"),
				ui.node("spacer", { key = "fill", grow = 1 }),
				keyed(button("Cancel", "cancel", { "escape" }), "no"),
				keyed(button(if merge then METHOD_LABEL[method] or "Merge" else "Close PR", "confirm", { "enter" }, if merge then "primary" else "danger"), "yes"),
			}),
			{ align = "center", gap = "sm" }
		)
	end
	local busy = d.busy ~= nil
	local row: { Node } = {}
	local function maybe(action: string, label: string, keys: { string }, variant: string?)
		if pr.can(action, p) then
			table.insert(row, keyed(button(if d.busy == action then "Working…" else label, action, keys, variant, busy), action))
		end
	end
	maybe("close", "Close", { "x" }, "danger")
	maybe("reopen", "Reopen", {})
	maybe("ready", "Ready for review", { "d" })
	maybe("update-branch", "Update branch", { "u" })
	maybe("rerun", "Re-run failed", { "f" })
	table.insert(row, ui.node("spacer", { key = "fill", grow = 1 }))
	table.insert(row, keyed(button("Copy link", "copy", { "c" }), "copy"))
	table.insert(row, keyed(button("GitHub", "open", { "o" }), "open"))
	maybe("merge", METHOD_LABEL[method] or "Merge", { "m" }, "primary")
	return with(ui.row(row), { align = "center", gap = "sm" })
end

-- ── Input ─────────────────────────────────────────────────────────────────────────────────────

function M.open(d: Detail, cx: BlockCx)
	cx:open(if d.pr then d.pr.url else d.ref.url)
end

-- A click in the view; false when it is not the view's.
function M.event(d: Detail, ev: UiEvent, cx: BlockCx, render: () -> ()): boolean
	if ev.ev == "select" and type(ev.item) == "string" and table.find(TABS, ev.item) then
		M.set_tab(d, ev.item, render)
		return true
	elseif ev.ev ~= "action" then
		return false
	end
	local a, v = ev.act, ev.value
	if a == "tab" and type(v) == "string" then
		M.set_tab(d, v, render)
	elseif a == "do" and v == "cancel" then
		d.confirm = nil
	elseif a == "do" and v == "confirm" and d.confirm then
		act(d, d.confirm, cx, render)
	elseif a == "do" and v == "copy" then
		cx:copy(if d.pr then d.pr.url else d.ref.url)
		cx:toast("info", "Copied the pull request's URL")
	elseif a == "do" and v == "open" then
		M.open(d, cx)
	elseif a == "do" and (v == "merge" or v == "close") then
		if d.pr and pr.can(v, d.pr) then
			d.confirm = v
		end
	elseif a == "do" and type(v) == "string" then
		act(d, v, cx, render)
	else
		return false
	end
	return true
end

local function scroll(cx: BlockCx, to: string)
	cx:frame({ { "scroll", "main", to } })
end

-- A key in the view; false for a key it leaves to the block (Escape goes back to the list).
function M.key(d: Detail, key: Key, cx: BlockCx, render: () -> ()): boolean
	local name = key.name
	if d.confirm then
		if name == "enter" or name == "y" then
			act(d, d.confirm, cx, render)
		elseif name == "escape" or name == "n" then
			d.confirm = nil
		end
		return true
	end
	local bare = not key.ctrl and not key.alt and not key.meta
	local at = table.find(TABS, d.tab) or 1
	if name == "tab" then
		M.set_tab(d, TABS[(at - 1 + (if key.shift then -1 else 1)) % #TABS + 1], render)
	elseif bare and (name == "1" or name == "2" or name == "3") then
		M.set_tab(d, TABS[tonumber(name) :: number], render)
	elseif bare and (name == "down" or name == "j") then
		scroll(cx, "line-down")
	elseif bare and (name == "up" or name == "k") then
		scroll(cx, "line-up")
	elseif name == "page_down" or (bare and name == "space") then
		scroll(cx, "page-down")
	elseif name == "page_up" then
		scroll(cx, "page-up")
	elseif name == "home" or (bare and name == "g" and not key.shift) then
		scroll(cx, "start")
	elseif name == "end" or (bare and key.text == "G") then
		scroll(cx, "end")
	elseif bare and name == "o" then
		M.open(d, cx)
	elseif bare and name == "c" then
		cx:copy(if d.pr then d.pr.url else d.ref.url)
		cx:toast("info", "Copied the pull request's URL")
	elseif bare and (name == "m" or name == "x") then
		local v = if name == "m" then "merge" else "close"
		if d.pr and pr.can(v, d.pr) then
			d.confirm = v
		end
	elseif bare and name == "d" then
		act(d, "ready", cx, render)
	elseif bare and name == "u" then
		act(d, "update-branch", cx, render)
	elseif bare and name == "f" then
		act(d, "rerun", cx, render)
	elseif (key.ctrl and name == "r") or (bare and name == "r") then
		M.load(d, render)
	else
		return false
	end
	return true
end

return M
