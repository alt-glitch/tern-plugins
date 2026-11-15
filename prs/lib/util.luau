--!strict
-- Small helpers shared by the list and the detail view: times, text and JSON values.

local M = {}

-- Seconds since the epoch of an ISO 8601 UTC time, by the days-from-civil algorithm: `os.time`
-- with a table reads local time.
function M.epoch(iso: any): number?
	if type(iso) ~= "string" then
		return nil
	end
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

-- How long ago `t` was, compactly: `12m`, `5h`, `3d`.
function M.age(t: number): string
	local s = math.max(0, os.time() - t)
	if s < 3600 then
		return math.max(1, s // 60) .. "m"
	elseif s < 86400 then
		return s // 3600 .. "h"
	elseif s < 86400 * 60 then
		return s // 86400 .. "d"
	end
	return s // (86400 * 30) .. "mo"
end

-- `5m ago` for an ISO time; "" when it is not one.
function M.ago(iso: any): string
	local t = M.epoch(iso)
	return if t then M.age(t) .. " ago" else ""
end

-- A whole duration in seconds: `42s`, `3m 10s`, `1h 5m`.
function M.duration(s: number): string
	s = math.max(0, math.floor(s))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return s // 60 .. "m " .. s % 60 .. "s"
	end
	return s // 3600 .. "h " .. (s % 3600) // 60 .. "m"
end

function M.plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

-- Thousands separators: 12345 -> 12,345.
function M.thousands(n: number): string
	local s = tostring(math.floor(n))
	local out = string.reverse((string.gsub(string.reverse(s), "(%d%d%d)", "%1,")))
	return (string.gsub(out, "^,", ""))
end

function M.first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

-- A JSON string field, or "" for null, a missing field or another type.
function M.str(v: any): string
	return if type(v) == "string" then v else ""
end

-- A JSON number field, or 0.
function M.num(v: any): number
	return if type(v) == "number" then v else 0
end

-- A JSON object field, or an empty table, so chains like `M.obj(M.obj(x).a).b` never fail.
function M.obj(v: any): { [string]: any }
	return if type(v) == "table" then v else {}
end

-- The `nodes` of a GraphQL connection, keeping only objects.
function M.nodes(v: any): { { [string]: any } }
	local out = {}
	local nodes = M.obj(v).nodes
	if type(nodes) == "table" then
		for _, n in nodes do
			if type(n) == "table" then
				table.insert(out, n)
			end
		end
	end
	return out
end

-- A login, or `ghost` for a deleted account.
function M.login(v: any): string
	local l = M.str(M.obj(v).login)
	return if l == "" then "ghost" else l
end

return M
