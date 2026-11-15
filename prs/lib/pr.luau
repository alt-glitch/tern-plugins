--!strict
-- One pull request as the detail view shows it, read with GitHub's GraphQL API through `gh`.
-- The fields and the check mapping follow T3 Code's PullRequestCore query and
-- gitHubPullRequestJson.ts (MIT, T3 Tools Inc.), cut down to what the block draws.

local gh = require("./gh")
local util = require("./util")

local M = {}

export type Ref = { repo: string, number: number, url: string }

export type Check = {
	name: string,
	workflow: string?,
	status: string, -- success | failure | cancelled | pending | action-required | skipped | neutral
	url: string?,
	description: string?,
	started: number?,
	completed: number?,
}

export type Reviewer = { login: string, state: string }

export type Pr = {
	id: string,
	repo: string,
	number: number,
	url: string,
	title: string,
	body: string,
	state: string, -- open | merged | closed
	draft: boolean,
	author: string,
	head: string,
	base: string,
	head_oid: string,
	additions: number,
	deletions: number,
	changed_files: number,
	mergeable: string, -- mergeable | conflicting | unknown
	review_decision: string,
	labels: { string },
	reviewers: { Reviewer },
	checks: { Check },
	created: string,
	updated: string,
	merged: string,
	closed: string,
	methods: { string }, -- squash | merge | rebase, preferred first
	can_update: boolean,
	behind_by: number?,
	auto_merge: string,
	-- The signed-in user's login, to tell whether they may review.
	viewer: string,
}

export type Activity = {
	kind: string, -- comment | review | thread | commit
	author: string,
	-- Written by a GitHub App (CI bots, review bots).
	bot: boolean?,
	at: number,
	body: string,
	url: string?,
	state: string?,
	path: string?,
	line: number?,
	resolved: boolean?,
	outdated: boolean?,
	replies: { { author: string, body: string, at: number } }?,
}

export type File = { path: string, status: string, additions: number, deletions: number, patch: string?, previous: string? }

local CHECK_FIELDS = [[
  __typename
  ... on CheckRun { name status conclusion startedAt completedAt detailsUrl
    checkSuite { workflowRun { workflow { name } } } }
  ... on StatusContext { context state targetUrl description createdAt }]]

local DETAIL_QUERY = [[query($o: String!, $r: String!, $n: Int!, $h: String!) {
  viewer { login }
  repository(owner: $o, name: $r) {
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    pullRequest(number: $n) {
      id number title url body state isDraft mergeable reviewDecision
      additions deletions changedFiles createdAt updatedAt mergedAt closedAt
      headRefName baseRefName headRefOid viewerCanUpdate
      author { login }
      autoMergeRequest { mergeMethod }
      baseRef { compare(headRef: $h) { behindBy } }
      labels(first: 20) { nodes { name } }
      reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Team { name } } } }
      latestReviews(first: 20) { nodes { author { login } state } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes { ]] .. CHECK_FIELDS .. [[ } } } } } }
    }
  }
}]]

local ACTIVITY_QUERY = [[query($o: String!, $r: String!, $n: Int!) {
  repository(owner: $o, name: $r) { pullRequest(number: $n) {
    comments(last: 50) { nodes { author { __typename login } body createdAt url } }
    reviews(last: 30) { nodes { author { __typename login } state body submittedAt url } }
    reviewThreads(last: 50) { nodes { isResolved isOutdated path line
      comments(first: 20) { nodes { author { login } body createdAt url } } } }
    commits(last: 30) { nodes { commit { oid messageHeadline committedDate url author { name user { login } } } } }
  } }
}]]

-- `owner/repo#12` and the PR's URL from a URL or the parts; nil for anything else.
function M.ref(url: string?, repo: string?, number: number?): Ref?
	if url then
		local owner, name, n = string.match(url, "^https://github%.com/([%w._-]+)/([%w._-]+)/pull/(%d+)")
		if owner and name and n then
			return { repo = owner .. "/" .. name, number = tonumber(n) :: number, url = "https://github.com/" .. owner .. "/" .. name .. "/pull/" .. n }
		end
	end
	if repo and number and string.match(repo, "^[%w._-]+/[%w._-]+$") then
		return { repo = repo, number = number, url = "https://github.com/" .. repo .. "/pull/" .. number }
	end
	return nil
end

-- `owner/repo#12`, lower case: GitHub names are case-insensitive, and list files may write either.
function M.key(ref: Ref): string
	return string.lower(ref.repo) .. "#" .. ref.number
end

-- T3 Code's check status mapping.
local function check_status(status: string, conclusion: string): string
	if status ~= "" and status ~= "COMPLETED" then
		return "pending"
	end
	if conclusion == "SUCCESS" then
		return "success"
	elseif conclusion == "ACTION_REQUIRED" then
		return "action-required"
	elseif conclusion == "FAILURE" or conclusion == "ERROR" or conclusion == "TIMED_OUT" or conclusion == "STARTUP_FAILURE" then
		return "failure"
	elseif conclusion == "CANCELLED" then
		return "cancelled"
	elseif conclusion == "SKIPPED" then
		return "skipped"
	elseif conclusion == "PENDING" or conclusion == "EXPECTED" then
		return "pending"
	end
	return "neutral"
end

local function parse_check(n: { [string]: any }): Check
	local function opt(s: string): string?
		return if s ~= "" then s else nil
	end
	if util.str(n.__typename) == "StatusContext" then
		return {
			name = util.str(n.context),
			status = check_status("COMPLETED", util.str(n.state)),
			url = opt(util.str(n.targetUrl)),
			description = opt(util.str(n.description)),
			started = util.epoch(n.createdAt),
		}
	end
	local workflow = util.str(util.obj(util.obj(util.obj(n.checkSuite).workflowRun).workflow).name)
	return {
		name = util.str(n.name),
		workflow = opt(workflow),
		status = check_status(util.str(n.status), util.str(n.conclusion)),
		url = opt(util.str(n.detailsUrl)),
		started = util.epoch(n.startedAt),
		completed = util.epoch(n.completedAt),
	}
end

-- Re-runs repeat a check: keep the newest per (workflow, name), and qualify a name two workflows
-- share as `Workflow / name` (T3 Code's pullRequestChecks.ts).
local function dedupe(checks: { Check }): { Check }
	local newest: { [string]: Check } = {}
	local order: { string } = {}
	local function time(c: Check): number
		return c.completed or c.started or 0
	end
	for _, c in checks do
		local key = (c.workflow or "") .. "\0" .. c.name
		local prev = newest[key]
		if not prev then
			table.insert(order, key)
		end
		if not prev or time(c) >= time(prev) then
			newest[key] = c
		end
	end
	local workflows: { [string]: { [string]: boolean } } = {}
	for _, key in order do
		local c = newest[key]
		workflows[c.name] = workflows[c.name] or {}
		workflows[c.name][c.workflow or ""] = true
	end
	local out: { Check } = {}
	for _, key in order do
		local c = newest[key]
		local n = 0
		for _ in workflows[c.name] do
			n += 1
		end
		if n > 1 and c.workflow then
			c.name = c.workflow .. " / " .. c.name
		end
		table.insert(out, c)
	end
	return out
end

local STATE = { OPEN = "open", MERGED = "merged", CLOSED = "closed" }
local MERGEABLE = { MERGEABLE = "mergeable", CONFLICTING = "conflicting" }

local function parse_detail(ref: Ref, data: any): Pr?
	local repo = util.obj(util.obj(data).repository)
	local p = repo.pullRequest
	if type(p) ~= "table" then
		return nil
	end
	local reviewers: { Reviewer } = {}
	local seen: { [string]: boolean } = {}
	for _, n in util.nodes(p.reviewRequests) do
		local r = util.obj(n.requestedReviewer)
		local login = if util.str(r.login) ~= "" then util.str(r.login) else util.str(r.name)
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(reviewers, { login = login, state = "PENDING" })
		end
	end
	-- Someone who reviewed drops off reviewRequests: their latest review stands for them.
	for _, n in util.nodes(p.latestReviews) do
		local login = util.str(util.obj(n.author).login)
		if login ~= "" and not seen[login] then
			seen[login] = true
			table.insert(reviewers, { login = login, state = util.str(n.state) })
		end
	end
	local checks: { Check } = {}
	local last = util.nodes(p.commits)[1]
	if last then
		for _, n in util.nodes(util.obj(util.obj(last.commit).statusCheckRollup).contexts) do
			table.insert(checks, parse_check(n))
		end
	end
	local labels: { string } = {}
	for _, n in util.nodes(p.labels) do
		table.insert(labels, util.str(n.name))
	end
	local methods: { string } = {}
	if repo.squashMergeAllowed == true then
		table.insert(methods, "squash")
	end
	if repo.mergeCommitAllowed == true then
		table.insert(methods, "merge")
	end
	if repo.rebaseMergeAllowed == true then
		table.insert(methods, "rebase")
	end
	local behind = util.obj(util.obj(p.baseRef).compare).behindBy
	return {
		id = util.str(p.id),
		repo = ref.repo,
		number = ref.number,
		url = if util.str(p.url) ~= "" then util.str(p.url) else ref.url,
		title = util.str(p.title),
		body = util.str(p.body),
		state = STATE[util.str(p.state)] or "open",
		draft = p.isDraft == true,
		author = util.login(p.author),
		head = util.str(p.headRefName),
		base = util.str(p.baseRefName),
		head_oid = util.str(p.headRefOid),
		additions = util.num(p.additions),
		deletions = util.num(p.deletions),
		changed_files = util.num(p.changedFiles),
		mergeable = MERGEABLE[util.str(p.mergeable)] or "unknown",
		review_decision = util.str(p.reviewDecision),
		labels = labels,
		reviewers = reviewers,
		checks = dedupe(checks),
		created = util.str(p.createdAt),
		updated = util.str(p.updatedAt),
		merged = util.str(p.mergedAt),
		closed = util.str(p.closedAt),
		methods = methods,
		can_update = p.viewerCanUpdate == true,
		behind_by = if type(behind) == "number" then behind else nil,
		auto_merge = util.str(util.obj(p.autoMergeRequest).mergeMethod),
		viewer = util.str(util.obj(util.obj(data).viewer).login),
	}
end

local function owner_name(ref: Ref): (string, string)
	local owner, name = string.match(ref.repo, "^([^/]+)/(.+)$")
	return owner or "", name or ""
end

function M.load(ref: Ref, done: (Pr?, gh.Problem?) -> ())
	local owner, name = owner_name(ref)
	gh.graphql(DETAIL_QUERY, { o = owner, r = name, n = ref.number, h = "refs/pull/" .. ref.number .. "/head" }, function(data, problem)
		if problem then
			done(nil, problem)
			return
		end
		local pr = parse_detail(ref, data)
		done(pr, if pr then nil else { kind = "failed", text = "GitHub has no such pull request, or you cannot see it." })
	end)
end

-- Everything said and pushed on the PR, oldest first. Reviews with no words and no verdict are dropped.
function M.activity(ref: Ref, done: ({ Activity }?, gh.Problem?) -> ())
	local owner, name = owner_name(ref)
	gh.graphql(ACTIVITY_QUERY, { o = owner, r = name, n = ref.number }, function(data, problem)
		if problem then
			done(nil, problem)
			return
		end
		local p = util.obj(util.obj(util.obj(data).repository).pullRequest)
		local items: { Activity } = {}
		for _, n in util.nodes(p.comments) do
			table.insert(items, { kind = "comment", author = util.login(n.author), bot = util.obj(n.author).__typename == "Bot", at = util.epoch(n.createdAt) or 0, body = util.str(n.body), url = util.str(n.url) })
		end
		for _, n in util.nodes(p.reviews) do
			local body, st = util.str(n.body), util.str(n.state)
			if string.match(body, "%S") or st ~= "COMMENTED" then
				table.insert(items, { kind = "review", author = util.login(n.author), bot = util.obj(n.author).__typename == "Bot", at = util.epoch(n.submittedAt) or 0, body = body, url = util.str(n.url), state = st })
			end
		end
		for _, t in util.nodes(p.reviewThreads) do
			local comments = util.nodes(t.comments)
			local first = comments[1]
			if first then
				local replies = {}
				for i = 2, #comments do
					local c = comments[i]
					table.insert(replies, { author = util.login(c.author), body = util.str(c.body), at = util.epoch(c.createdAt) or 0 })
				end
				table.insert(items, {
					kind = "thread",
					author = util.login(first.author),
					at = util.epoch(first.createdAt) or 0,
					body = util.str(first.body),
					url = util.str(first.url),
					path = util.str(t.path),
					line = if type(t.line) == "number" then t.line else nil,
					resolved = t.isResolved == true,
					outdated = t.isOutdated == true,
					replies = replies,
				})
			end
		end
		for _, n in util.nodes(p.commits) do
			local c = util.obj(n.commit)
			local who = util.obj(c.author)
			local login = util.str(util.obj(who.user).login)
			table.insert(items, {
				kind = "commit",
				author = if login ~= "" then login elseif util.str(who.name) ~= "" then util.str(who.name) else "ghost",
				at = util.epoch(c.committedDate) or 0,
				body = util.str(c.messageHeadline),
				url = util.str(c.url),
			})
		end
		table.sort(items, function(a, b)
			return a.at < b.at
		end)
		done(items, nil)
	end)
end

-- The changed files with their patches: the first 100, as one page of the REST API.
function M.files(ref: Ref, done: ({ File }?, gh.Problem?) -> ())
	gh.json({ "api", "repos/" .. ref.repo .. "/pulls/" .. ref.number .. "/files?per_page=100" }, function(rows, problem)
		if problem then
			done(nil, problem)
			return
		end
		local files: { File } = {}
		if type(rows) == "table" then
			for _, r in rows do
				if type(r) == "table" then
					local patch, previous = util.str(r.patch), util.str(r.previous_filename)
					table.insert(files, {
						path = util.str(r.filename),
						status = util.str(r.status),
						additions = util.num(r.additions),
						deletions = util.num(r.deletions),
						patch = if patch ~= "" then patch else nil,
						previous = if previous ~= "" then previous else nil,
					})
				end
			end
		end
		done(files, nil)
	end)
end

-- Light facts for many PRs at once (the session list): one aliased query, literals validated by M.ref.
function M.summaries(refs: { Ref }, done: ({ [string]: { [string]: any } }?, gh.Problem?) -> ())
	if #refs == 0 then
		done({}, nil)
		return
	end
	local parts = {}
	for i, ref in refs do
		local owner, name = owner_name(ref)
		table.insert(
			parts,
			string.format(
				'p%d: repository(owner: "%s", name: "%s") { pullRequest(number: %d) { title state isDraft updatedAt author { login } } }',
				i,
				owner,
				name,
				ref.number
			)
		)
	end
	gh.graphql("query { " .. table.concat(parts, "\n") .. " }", {}, function(data, problem)
		if problem and not data then
			done(nil, problem)
			return
		end
		local out = {}
		for i, ref in refs do
			local p = util.obj(util.obj(util.obj(data)["p" .. i]).pullRequest)
			if p.title then
				out[M.key(ref)] = p
			end
		end
		done(out, nil)
	end)
end

-- ── How a PR reads ────────────────────────────────────────────────────────────────────────────

function M.state_label(pr: Pr): string
	return if pr.state == "open" then (if pr.draft then "Draft" else "Open") elseif pr.state == "merged" then "Merged" else "Closed"
end

function M.state_tone(pr: Pr): string
	return if pr.state == "merged" then "accent" elseif pr.state == "closed" then "error" elseif pr.draft then "muted" else "success"
end

-- failing | pending | passing | none
function M.checks_state(checks: { Check }): string
	if #checks == 0 then
		return "none"
	end
	local pending = false
	for _, c in checks do
		if c.status == "failure" or c.status == "cancelled" then
			return "failing"
		end
		pending = pending or c.status == "pending" or c.status == "action-required"
	end
	return if pending then "pending" else "passing"
end

function M.checks_tone(checks: { Check }): string
	local s = M.checks_state(checks)
	return if s == "failing" then "error" elseif s == "pending" then "warning" elseif s == "passing" then "success" else "muted"
end

-- `2 failing, 1 pending, 9 passing`.
function M.checks_summary(checks: { Check }): string
	if #checks == 0 then
		return "No checks"
	end
	local counts: { [string]: number } = {}
	for _, c in checks do
		counts[c.status] = (counts[c.status] or 0) + 1
	end
	local parts = {}
	for _, pair in
		{
			{ "failure", "failing" },
			{ "cancelled", "cancelled" },
			{ "action-required", "waiting for approval" },
			{ "pending", "pending" },
			{ "success", "passing" },
		}
	do
		local n = counts[pair[1]]
		if n then
			table.insert(parts, n .. " " .. pair[2])
		end
	end
	local skipped = (counts.skipped or 0) + (counts.neutral or 0)
	if skipped > 0 then
		table.insert(parts, skipped .. " skipped")
	end
	return table.concat(parts, ", ")
end

-- The Actions run ids behind failed checks, for "Re-run failed".
function M.failed_runs(checks: { Check }): { string }
	local ids, seen = {}, {}
	for _, c in checks do
		if (c.status == "failure" or c.status == "cancelled") and c.url then
			local id = string.match(c.url, "/actions/runs/(%d+)")
			if id and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
	end
	return ids
end

-- Whether `action` applies to `pr` as it stands.
function M.can(action: string, pr: Pr): boolean
	local open = pr.state == "open"
	if action == "merge" then
		return open and not pr.draft and pr.can_update and pr.mergeable ~= "conflicting"
	elseif action == "ready" then
		return open and pr.draft and pr.can_update
	elseif action == "close" then
		return open and pr.can_update
	elseif action == "reopen" then
		return pr.state == "closed" and pr.can_update
	elseif action == "update-branch" then
		return open and (pr.behind_by or 0) > 0
	elseif action == "rerun" then
		return open and #M.failed_runs(pr.checks) > 0
	elseif action == "approve" then
		return open and not pr.draft and pr.viewer ~= "" and pr.viewer ~= pr.author
	elseif action == "review" then
		return open and pr.viewer ~= ""
	end
	return false
end

-- The review verdicts `pr` takes from the signed-in user, in the form's order. GitHub refuses an
-- approval or a change request on your own pull request, and on a draft.
function M.review_kinds(pr: Pr): { string }
	if M.can("approve", pr) then
		return { "comment", "approve", "request" }
	end
	return { "comment" }
end

local REVIEW_FLAG = { comment = "--comment", approve = "--approve", request = "--request-changes" }

-- Submits a review: `kind` is comment | approve | request; `body` may be empty only to approve.
function M.review(pr: Pr, kind: string, body: string, done: (gh.Problem?) -> ())
	local args = { "pr", "review", tostring(pr.number), "-R", pr.repo, REVIEW_FLAG[kind] or "--comment" }
	if body ~= "" then
		table.insert(args, "-b")
		table.insert(args, body)
	end
	gh.act(args, done)
end

-- Runs `action` on `pr` with `gh`; `done(problem?)` once every command finished.
function M.act(action: string, pr: Pr, done: (gh.Problem?) -> ())
	local n, repo = tostring(pr.number), pr.repo
	if action == "merge" then
		gh.act({ "pr", "merge", n, "-R", repo, "--" .. (pr.methods[1] or "merge") }, done)
	elseif action == "approve" then
		gh.act({ "pr", "review", n, "-R", repo, "--approve" }, done)
	elseif action == "rerun" then
		local runs = M.failed_runs(pr.checks)
		local left, failed = #runs, nil :: gh.Problem?
		for _, id in runs do
			gh.act({ "run", "rerun", id, "--failed", "-R", repo }, function(problem)
				failed = failed or problem
				left -= 1
				if left == 0 then
					done(failed)
				end
			end)
		end
	else
		gh.act({ "pr", action, n, "-R", repo }, done)
	end
end

return M
