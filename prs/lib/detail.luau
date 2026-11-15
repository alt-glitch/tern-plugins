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

-- What the block remembers across pages and restarts.
export type Prefs = {
	filter: string, -- all | comments | commits: what the Conversation tab shows
	newest: boolean, -- the Conversation tab newest first
	method: string?, -- the merge method used last
}

export type Detail = {
	ref: pr.Ref,
	prefs: Prefs,
	pr: pr.Pr?,
	problem: gh.Problem?,
	loading: boolean,
	tab: string, -- conversation | checks | files
	activity: { pr.Activity }?,
	activity_problem: gh.Problem?,
	files: { pr.File }?,
	files_problem: gh.Problem?,
	confirm: string?, -- merge | close | approve | disable-auto
	-- The merge method picked in the merge question.
	method: string?,
	-- The review form in the dock while it is open; `cursor` is a byte offset into `text`.
	review: Review?,
	-- What the list row already knew, drawn while GitHub answers.
	seed: { title: string, author: string }?,
	-- Comments and reviews by GitHub Apps show; hidden by default, as T3 Code does.
	bots: boolean,
	busy: string?, -- the action running now
	-- Bumped on every load, so an answer for an older load or another PR is dropped.
	generation: number,
}

export type Review = { text: string, cursor: number, kind: string }

local TABS = { "conversation", "checks", "files" }
local REVIEW_LABEL = { comment = "Comment", approve = "Approve", request = "Request changes" }
local LONG_DIFF = 400

local METHOD_LABEL = { merge = "Merge", squash = "Squash and merge", rebase = "Rebase and merge" }
local METHOD_SHORT = { merge = "Merge commit", squash = "Squash", rebase = "Rebase" }
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

local FILTERS = { "all", "comments", "commits" }
local FILTER_LABEL = { all = "All", comments = "Comments", commits = "Commits" }

-- Prefs from what `save` stored, with defaults for anything missing or unknown.
function M.prefs(saved: any): Prefs
	local was = if type(saved) == "table" then saved else {}
	return {
		filter = if table.find(FILTERS, was.filter) then was.filter else "all",
		newest = was.newest == true,
		method = if type(was.method) == "string" then was.method else nil,
	}
end

function M.new(ref: pr.Ref, prefs: Prefs, seed: { title: string, author: string }?): Detail
	return {
		ref = ref,
		prefs = prefs,
		pr = nil,
		problem = nil,
		loading = false,
		tab = "conversation",
		activity = nil,
		activity_problem = nil,
		files = nil,
		files_problem = nil,
		confirm = nil,
		method = nil,
		review = nil,
		seed = seed,
		bots = false,
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

-- The merge method to offer: the one picked in the question, else the one this block merged with
-- last, else the repository's preferred one, each only while the repository allows it.
local function merge_method(d: Detail, p: pr.Pr): string
	for _, m in { d.method, d.prefs.method } do
		if m and table.find(p.methods, m) then
			return m
		end
	end
	return p.methods[1] or "merge"
end

local function merge(d: Detail, auto: boolean, cx: BlockCx, render: () -> ())
	local p = d.pr
	d.confirm = nil
	if not p or d.busy or not pr.can(if auto then "merge-auto" else "merge", p) then
		return
	end
	local method = merge_method(d, p)
	d.busy = "merge"
	pr.merge(p, method, auto, function(problem)
		d.busy = nil
		if problem then
			cx:toast("error", "Could not merge #" .. p.number, problem.text)
		else
			d.prefs.method = method
		end
		M.load(d, render)
	end)
end

local function act(d: Detail, action: string, cx: BlockCx, render: () -> ())
	if action == "merge" then
		merge(d, d.pr ~= nil and pr.can("merge-auto", d.pr), cx, render)
		return
	end
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

-- Whether the dock holds a question or the review form, which take every key until they close.
function M.modal(d: Detail): boolean
	return d.confirm ~= nil or d.review ~= nil
end

local function open_review(d: Detail, cx: BlockCx)
	if d.pr and pr.can("review", d.pr) and not d.busy then
		d.confirm = nil
		d.review = { text = "", cursor = 0, kind = "comment" }
		-- The field exists only after this frame is drawn, so the focus op waits a tick.
		tern.timer(0, function()
			cx:frame({ { "focus", "dock.review.body" } })
		end)
	end
end

local function submit_review(d: Detail, cx: BlockCx, render: () -> ())
	local p, r = d.pr, d.review
	if not p or not r or d.busy then
		return
	end
	local body = string.match(r.text, "^%s*(.-)%s*$") or ""
	if body == "" and r.kind ~= "approve" then
		cx:toast("error", REVIEW_LABEL[r.kind] .. " needs some text")
		return
	end
	d.busy = "review"
	pr.review(p, r.kind, body, function(problem)
		d.busy = nil
		if problem then
			cx:toast("error", "Could not review #" .. p.number, problem.text)
			render()
			return
		end
		d.review = nil
		cx:toast("info", "Review sent on #" .. p.number)
		M.load(d, render)
	end)
end

local function utf16_len(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += if c > 0xFFFF then 2 else 1
	end
	return n
end

-- Edits the review text from a key; the form owns every key while it is open.
local function review_key(d: Detail, r: Review, key: Key, cx: BlockCx, render: () -> ())
	local name, text, at = key.name, r.text, r.cursor
	if name == "escape" then
		d.review = nil
	elseif name == "enter" and (key.ctrl or key.meta) then
		submit_review(d, cx, render)
	elseif name == "tab" and d.pr then
		local kinds = pr.review_kinds(d.pr)
		local i = table.find(kinds, r.kind) or 1
		r.kind = kinds[(i - 1 + (if key.shift then -1 else 1)) % #kinds + 1]
	elseif name == "enter" then
		r.text, r.cursor = string.sub(text, 1, at) .. "\n" .. string.sub(text, at + 1), at + 1
	elseif name == "backspace" and at > 0 then
		local from = utf8.offset(text, -1, at + 1) or at
		r.text, r.cursor = string.sub(text, 1, from - 1) .. string.sub(text, at + 1), from - 1
	elseif name == "delete" and at < #text then
		local to = utf8.offset(text, 2, at + 1) or (at + 2)
		r.text = string.sub(text, 1, at) .. string.sub(text, to)
	elseif name == "left" and at > 0 then
		r.cursor = (utf8.offset(text, -1, at + 1) or at) - 1
	elseif name == "right" and at < #text then
		r.cursor = (utf8.offset(text, 2, at + 1) or (at + 2)) - 1
	elseif name == "home" or (key.ctrl and name == "a") then
		r.cursor = 0
	elseif name == "end" or (key.ctrl and name == "e") then
		r.cursor = #text
	elseif key.text and key.text ~= "" and not key.ctrl then
		local typed = string.gsub(key.text, "\r\n?", "\n")
		r.text, r.cursor = string.sub(text, 1, at) .. typed .. string.sub(text, at + 1), at + #typed
	end
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
	-- Review bots badge findings with a linked image (`<a><img alt="P1"></a>`): keep the label.
	text = string.gsub(text, "<img[^>]-alt=\"([^\"]*)\"[^>]*>", "**%1**")
	text = string.gsub(text, "<img[^>]*>", "")
	text = string.gsub(text, "<a%s[^>]*>", "")
	text = string.gsub(text, "</a>", "")
	if not string.match(text, "%S") then
		return keyed(ui.text({ ui.span(empty or "No description provided.", "muted") }), key)
	end
	return keyed(ui.md(text), key)
end

-- The GitHub stack this PR is a layer of, folded to one line: every layer bottom first, this one
-- marked; picking another layer opens it (the host does, as `layer=<number>`).
local function stack_card(p: pr.Pr, s: pr.Stack): Node
	local rows: { Node } = {}
	for _, l in s.layers do
		local here = l.number == p.number
		local spans: { any } = {
			ui.span(string.format("%2d  ", l.position), "dim mono"),
			ui.span("#" .. l.number .. "  ", "muted"),
			ui.span(l.title, if here then "strong" else nil),
			ui.span("  " .. pr.state_label(l), pr.state_tone(l)),
		}
		local decision = DECISION[l.review]
		if decision and l.state == "open" then
			table.insert(spans, ui.span(" · " .. decision[1], decision[2]))
		end
		if here then
			table.insert(spans, ui.span("  ← this one", "dim"))
		end
		local row = keyed(ui.text(spans), "s" .. l.number)
		table.insert(rows, if here then row else clicky(row, "layer=" .. l.number))
	end
	table.insert(rows, keyed(ui.text({ ui.span("Each layer merges into the one under it; the bottom one into " .. s.base .. ".", "dim") }), "foot"))
	local merged = 0
	for _, l in s.layers do
		if l.state == "merged" then
			merged += 1
		end
	end
	local head = "Stack · " .. s.position .. " of " .. s.size .. (if merged > 0 then " · " .. merged .. " merged" else "")
	return keyed(with(ui.section(head, rows), { collapsible = true, collapsed = true }), "stack")
end

local function header(d: Detail): Node
	local p = d.pr
	local ref = d.ref
	local top: { Node } = {
		keyed(ui.text({ ui.link(ref.repo .. " #" .. ref.number, ref.url, "dim") }), "ref"),
	}
	if not p then
		local rows: { Node } = { keyed(ui.row(top), "top") }
		local seed = d.seed
		if seed then
			table.insert(rows, keyed(ui.text({ ui.span(seed.title, "strong") }), "title"))
			table.insert(rows, keyed(ui.text({ ui.span(seed.author, "strong") }), "who"))
		end
		local text = if d.problem then d.problem.text else "Reading GitHub…"
		table.insert(rows, keyed(ui.text({ ui.span(text, if d.problem then "error" else "muted") }), "status"))
		return with(ui.col(rows), { gap = "sm" })
	end
	local decision = DECISION[p.review_decision]
	if decision and p.state == "open" then
		table.insert(top, keyed(ui.badge(decision[1], decision[2]), "review"))
	end
	table.insert(top, keyed(ui.badge(pr.state_label(p), pr.state_tone(p)), "state"))
	if p.state == "open" and p.auto_merge ~= "" then
		table.insert(top, keyed(ui.badge("Auto-merge on (" .. string.lower(p.auto_merge) .. ")", "accent"), "auto"))
	end

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
	-- Whether the branch can merge as it stands: conflicts, or how far behind its base it is.
	if p.state == "open" and p.mergeable == "conflicting" then
		table.insert(rows, keyed(ui.text({ ui.span("Conflicts with " .. p.base .. ". Resolve them before merging.", "error") }), "mergeable"))
	elseif p.state == "open" and (p.behind_by or 0) > 0 then
		table.insert(
			rows,
			keyed(ui.text({ ui.span(util.plural(p.behind_by :: number, "commit") .. " behind " .. p.base, "warning"), ui.span(" · u updates the branch", "dim") }), "behind")
		)
	end
	local s = p.stack
	if s and #s.layers > 1 then
		table.insert(rows, stack_card(p, s))
	end
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

local function filter_bar(d: Detail): Node
	local items = {}
	for _, f in FILTERS do
		table.insert(items, { id = "filter:" .. f, label = FILTER_LABEL[f] })
	end
	local newest = d.prefs.newest
	return with(
		ui.row({
			ui.node("tabs", { key = "f", variant = "segmented", active = "filter:" .. d.prefs.filter, items = items }),
			ui.node("spacer", { key = "fill", grow = 1 }),
			keyed(
				clicky(ui.button("Newest first", { keys = { "n" }, size = "sm", variant = if newest then "primary" else nil :: any, icon = if newest then "check" else nil }), "newest"),
				"newest"
			),
		}),
		{ align = "center", gap = "sm" }
	)
end

local DESCRIPTION_LINES = 12

local function conversation(d: Detail, p: pr.Pr): { Node }
	local desc = comment("desc:" .. p.repo .. "#" .. p.number, { ui.span(p.author, "strong"), ui.span(" opened this", "muted") }, util.epoch(p.created) or 0, p.body, nil)
	-- A long description starts clamped, with the card's own "N more lines" control under it.
	desc = with(desc, { collapsible = true, collapsed = true, preview = { lines = DESCRIPTION_LINES } })
	local out: { Node } = { keyed(filter_bar(d), "filters"), desc }
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
	local hidden = 0
	local filter = d.prefs.filter
	local list = d.activity :: { pr.Activity }
	for n = 1, #list do
		local i = if d.prefs.newest then #list + 1 - n else n
		local a = list[i]
		if (filter == "commits") ~= (a.kind == "commit") and filter ~= "all" then
			continue
		end
		if a.bot and not d.bots then
			hidden += 1
			continue
		end
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
	if filter ~= "all" and #out == 2 then
		table.insert(out, keyed(ui.text({ ui.span(if filter == "commits" then "No commits." else "No comments yet.", "muted") }), "none"))
	end
	if hidden > 0 or d.bots then
		local text = if d.bots then "Hide comments by bots" else util.plural(hidden, "comment") .. " by bots hidden. Show them"
		table.insert(out, clicky(keyed(ui.text({ ui.span(text, "dim"), ui.span("  b", "dim mono") }), "bots"), "bots"))
	end
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

local function review_form(d: Detail, p: pr.Pr, r: Review): Node
	local kinds = pr.review_kinds(p)
	local items = {}
	for _, k in kinds do
		table.insert(items, { id = "review:" .. k, label = REVIEW_LABEL[k] })
	end
	local sending = d.busy == "review"
	local top: { Node } = {
		keyed(ui.text({ ui.span("Review #" .. p.number, "strong") }), "q"),
	}
	if #kinds > 1 then
		table.insert(top, ui.node("tabs", { key = "kind", variant = "segmented", active = "review:" .. r.kind, items = items }))
	end
	table.insert(top, ui.node("spacer", { key = "fill", grow = 1 }))
	table.insert(top, keyed(button("Cancel", "review-cancel", { "escape" }), "no"))
	table.insert(
		top,
		keyed(button(if sending then "Sending…" else REVIEW_LABEL[r.kind], "review-submit", { "ctrl+enter" }, if r.kind == "request" then "danger" else "primary", sending), "yes")
	)
	return keyed(
		with(
			ui.col({
				keyed(with(ui.row(top), { align = "center", gap = "sm" }), "top"),
				ui.node("editor", {
					key = "body",
					text = r.text,
					cursor = utf16_len(string.sub(r.text, 1, r.cursor)),
					placeholder = if r.kind == "approve" then "Optional note. Tab changes the verdict, ctrl+Enter sends." else "Write a review. Tab changes the verdict, ctrl+Enter sends.",
					maxLines = 8,
				}),
			}),
			{ gap = "sm" }
		),
		"review"
	)
end

function M.dock(d: Detail): Node?
	local p = d.pr
	if not p then
		return nil
	end
	if d.review then
		return review_form(d, p, d.review)
	end
	local method = merge_method(d, p)
	if d.confirm == "merge" then
		local auto = pr.can("merge-auto", p)
		local row: { Node } = {
			keyed(ui.text({ ui.span("Merge #" .. p.number .. " into "), ui.span(p.base, "mono"), ui.span(if auto then "? Checks are still running." else "?") }), "q"),
		}
		if #p.methods > 1 then
			local items = {}
			for _, m in p.methods do
				table.insert(items, { id = "method:" .. m, label = METHOD_SHORT[m] or m })
			end
			table.insert(row, ui.node("tabs", { key = "method", variant = "segmented", active = "method:" .. method, items = items }))
		end
		table.insert(row, ui.node("spacer", { key = "fill", grow = 1 }))
		table.insert(row, keyed(button("Cancel", "cancel", { "escape" }), "no"))
		if auto then
			table.insert(row, keyed(button("Merge now", "merge-now", nil), "now"))
			table.insert(row, keyed(button("Merge when ready", "confirm", { "enter" }, "primary"), "yes"))
		else
			table.insert(row, keyed(button(METHOD_LABEL[method] or "Merge", "confirm", { "enter" }, "primary"), "yes"))
		end
		return with(ui.row(row), { align = "center", gap = "sm" })
	elseif d.confirm then
		local approve = d.confirm == "approve"
		local off = d.confirm == "disable-auto"
		local question = if approve
			then { ui.span("Approve #" .. p.number .. " as " .. p.viewer .. "?") }
			elseif off then { ui.span("Turn off auto-merge for #" .. p.number .. "?") }
			else { ui.span("Close #" .. p.number .. " without merging?") }
		return with(
			ui.row({
				keyed(ui.text(question), "q"),
				ui.node("spacer", { key = "fill", grow = 1 }),
				keyed(button("Cancel", "cancel", { "escape" }), "no"),
				keyed(
					button(if approve then "Approve" elseif off then "Turn off" else "Close PR", "confirm", { "enter" }, if approve then "primary" else "danger"),
					"yes"
				),
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
	maybe("disable-auto", "Turn off auto-merge", {})
	table.insert(row, ui.node("spacer", { key = "fill", grow = 1 }))
	table.insert(row, keyed(button("Copy link", "copy", { "c" }), "copy"))
	table.insert(row, keyed(button("GitHub", "open", { "o" }), "open"))
	maybe("review", "Review", { "v" })
	maybe("approve", "Approve", { "a" })
	maybe("merge", if pr.can("merge-auto", p) then "Merge when ready" else METHOD_LABEL[method] or "Merge", { "m" }, "primary")
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
	elseif ev.ev == "select" and type(ev.item) == "string" and string.sub(ev.item, 1, 7) == "review:" then
		local r = d.review
		if r then
			r.kind = string.sub(ev.item, 8)
		end
		return true
	elseif ev.ev == "select" and type(ev.item) == "string" and string.sub(ev.item, 1, 7) == "method:" then
		d.method = string.sub(ev.item, 8)
		return true
	elseif ev.ev == "select" and type(ev.item) == "string" and string.sub(ev.item, 1, 7) == "filter:" then
		d.prefs.filter = string.sub(ev.item, 8)
		return true
	elseif ev.ev == "focus" and d.review and ev.id then
		cx:frame({ { "focus", ev.id } })
		return true
	elseif ev.ev ~= "action" then
		return false
	end
	local a, v = ev.act, ev.value
	if a == "tab" and type(v) == "string" then
		M.set_tab(d, v, render)
	elseif a == "do" and v == "cancel" then
		d.confirm = nil
	elseif a == "do" and v == "review" then
		open_review(d, cx)
	elseif a == "do" and v == "review-cancel" then
		d.review = nil
	elseif a == "do" and v == "review-submit" then
		submit_review(d, cx, render)
	elseif a == "do" and v == "confirm" and d.confirm then
		act(d, d.confirm, cx, render)
	elseif a == "do" and v == "merge-now" then
		merge(d, false, cx, render)
	elseif a == "do" and v == "copy" then
		cx:copy(if d.pr then d.pr.url else d.ref.url)
		cx:toast("info", "Copied the pull request's URL")
	elseif a == "do" and v == "open" then
		M.open(d, cx)
	elseif a == "bots" then
		d.bots = not d.bots
	elseif a == "newest" then
		d.prefs.newest = not d.prefs.newest
	elseif a == "do" and (v == "merge" or v == "close" or v == "approve" or v == "disable-auto") then
		if d.pr and pr.can(v, d.pr) then
			d.confirm = v
			d.method = nil
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
	local r = d.review
	if r then
		review_key(d, r, key, cx, render)
		return true
	end
	if d.confirm then
		local p = d.pr
		if d.confirm == "merge" and name == "tab" and p and #p.methods > 1 then
			local i = table.find(p.methods, merge_method(d, p)) or 1
			d.method = p.methods[(i - 1 + (if key.shift then -1 else 1)) % #p.methods + 1]
		elseif name == "enter" or name == "y" then
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
	elseif bare and name == "b" then
		d.bots = not d.bots
	elseif bare and name == "n" and d.tab == "conversation" then
		d.prefs.newest = not d.prefs.newest
	elseif bare and (name == "m" or name == "x" or name == "a") then
		local v = if name == "m" then "merge" elseif name == "a" then "approve" else "close"
		if d.pr and pr.can(v, d.pr) then
			d.confirm = v
			d.method = nil
		end
	elseif bare and name == "v" then
		open_review(d, cx)
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
