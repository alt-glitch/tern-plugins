--!strict
-- Running the GitHub CLI: finding it, reading its JSON, and saying what a failure means.

local util = require("./util")

local M = {}

local TIMEOUT_MS = 30 * 1000

-- `gh` by name first, then where package managers put it: a daemon started by launchd or
-- systemd often has a PATH without those directories.
local CANDIDATES = { "gh", "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/home/linuxbrew/.linuxbrew/bin/gh", "/usr/bin/gh" }

-- Why a call failed: `missing` (no gh), `auth` (gh is not signed in) or `failed`.
export type Problem = { kind: string, text: string, detail: string? }

function M.problem_of(result: ProcessResult): Problem
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
		return { kind = "auth", text = "The GitHub CLI is not signed in.", detail = util.first_lines(err, 3) }
	end
	local first = util.first_lines(err, 1)
	return {
		kind = "failed",
		text = if first ~= "" then first else "gh exited with status " .. result.status .. ".",
		detail = util.first_lines(err, 8),
	}
end

-- Starts `gh` with `args` in `cwd` (the daemon's directory when nil), trying each place it may be
-- installed. Calls `done` with the result, or returns the spawn error of the last attempt when none
-- starts.
function M.run(args: { string }, done: (ProcessResult) -> (), cwd: string?): string?
	local last = "gh is not on this machine's PATH"
	for _, gh in CANDIDATES do
		if gh == "gh" or tern.fs.exists(gh) then
			local argv: { string } = { gh }
			for _, a in args do
				table.insert(argv, a)
			end
			local opts: ProcessOptions = {
				timeout_ms = TIMEOUT_MS,
				env = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1", NO_COLOR = "1" },
				cwd = cwd,
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

-- Runs `gh` and decodes its JSON output: `done(value, nil)` or `done(nil, problem)`.
function M.json(args: { string }, done: (any, Problem?) -> (), cwd: string?)
	local spawn_error = M.run(args, function(result)
		if result.status ~= 0 then
			done(nil, M.problem_of(result))
			return
		end
		local ok, value = pcall(tern.json.decode, result.stdout)
		if ok then
			done(value, nil)
		else
			done(nil, { kind = "failed", text = "gh printed something other than JSON.", detail = util.first_lines(result.stdout, 4) })
		end
	end, cwd)
	if spawn_error then
		done(nil, { kind = "missing", text = "Tern could not start the GitHub CLI.", detail = spawn_error })
	end
end

-- A GraphQL query through `gh api graphql`; string variables go as `-f`, numbers as `-F`.
-- `done` gets the answer's `data`.
function M.graphql(query: string, vars: { [string]: string | number }, done: (any, Problem?) -> ())
	local args = { "api", "graphql", "-f", "query=" .. query }
	for k, v in vars do
		table.insert(args, if type(v) == "number" then "-F" else "-f")
		table.insert(args, k .. "=" .. tostring(v))
	end
	M.json(args, function(value, problem)
		if problem then
			done(nil, problem)
		elseif type(value) == "table" and type(value.data) == "table" then
			done(value.data, nil)
		else
			done(nil, { kind = "failed", text = "GitHub answered without data." })
		end
	end)
end

-- Runs a `gh` command whose output does not matter: `done(nil)` on success, else the problem.
function M.act(args: { string }, done: (Problem?) -> ())
	local spawn_error = M.run(args, function(result)
		done(if result.status == 0 then nil else M.problem_of(result))
	end)
	if spawn_error then
		done({ kind = "missing", text = "Tern could not start the GitHub CLI.", detail = spawn_error })
	end
end

return M
