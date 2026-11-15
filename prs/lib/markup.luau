--!strict
-- GitHub bodies are Markdown with HTML in it: PR templates, review bots and CI reports write
-- `<h2>`, `<sub>`, `<picture>` badges, `<table>`s and `<details>` folds. Tern's Markdown shows raw
-- HTML as text, so `parse` turns that HTML into Markdown and each `<details>` into its own part,
-- which the page draws as a collapsible section. Code (fences and inline spans) is left as written.

local M = {}

export type Part = { kind: "md", text: string } | { kind: "fold", summary: string, open: boolean, body: { Part } }

-- Code is swapped for `\1<n>\2` while the HTML is rewritten, then put back. `parse` runs to the end
-- in one go, so one list serves each call.
local OPEN, CLOSE = "\1", "\2"
local code: { string } = {}

local function stash(s: string): string
	table.insert(code, s)
	return OPEN .. #code .. CLOSE
end

-- Tags dropped with their content kept. Only these names are touched, so `Vec<String>` in prose stays.
local STRIP = {}
for _, t in
	{
		"sub", "sup", "small", "span", "font", "ins", "u", "center", "picture", "source", "g-emoji", "div",
		"blockquote", "thead", "tbody", "tfoot", "colgroup", "col", "dl", "dt", "dd", "abbr", "cite", "mark",
		"samp", "var", "a", "img", "table", "tr", "td", "th", "caption", "figure", "figcaption", "video",
	}
do
	STRIP[t] = true
end

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", mdash = "—", ndash = "–", hellip = "…", middot = "·", rarr = "→", larr = "←", times = "×", check = "✓" }

local function decode(s: string): string
	s = string.gsub(s, "&#([xX]?)(%x+);", (function(x: string, digits: string): string
		local n = tonumber(digits, if x == "" then 10 else 16)
		return if n and n < 0x110000 then utf8.char(n) else "&#" .. x .. digits .. ";"
	end) :: any)
	return (string.gsub(s, "&(%a+);", ENTITIES))
end

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") :: string)
end

local function attr(tag: string, name: string): string?
	local v = string.match(tag, "%s" .. name .. '%s*=%s*"([^"]*)"') or string.match(tag, "%s" .. name .. "%s*=%s*'([^']*)'")
	return if v then decode(v) else nil
end

-- One line: newlines to spaces, runs of spaces to one.
local function flat(s: string): string
	return trim((string.gsub(string.gsub(s, "%s*\n%s*", " "), "  +", " ")))
end

-- Swaps fenced code blocks and inline code spans for placeholders.
local function protect(text: string): string
	local out: { string } = {}
	local fence: string? = nil
	local block: { string } = {}
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if fence then
			table.insert(block, line)
			local run = string.match(line, "^%s*([`~]+)%s*$")
			if run and string.sub(run, 1, 1) == string.sub(fence, 1, 1) and #run >= #fence then
				table.insert(out, stash(table.concat(block, "\n")))
				fence, block = nil, {}
			end
			continue
		end
		local run = string.match(line, "^%s*(```+)") or string.match(line, "^%s*(~~~+)")
		if run then
			fence, block = run, { line }
			continue
		end
		-- Inline spans: a run of backticks up to the next run of the same length on this line.
		local parts: { string } = {}
		local i = 1
		while true do
			local s, e = string.find(line, "`+", i)
			if not s then
				break
			end
			local ticks = string.sub(line, s :: number, e :: number)
			local cs, ce = string.find(line, ticks, (e :: number) + 1, true)
			while cs and string.sub(line, (ce :: number) + 1, (ce :: number) + 1) == "`" do
				cs, ce = string.find(line, ticks, (ce :: number) + 2, true)
			end
			if not cs then
				break
			end
			table.insert(parts, string.sub(line, i, (s :: number) - 1))
			table.insert(parts, stash(string.sub(line, s :: number, ce :: number)))
			i = (ce :: number) + 1
		end
		table.insert(parts, string.sub(line, i))
		table.insert(out, table.concat(parts))
	end
	if fence then
		-- An unclosed fence runs to the end, as in CommonMark.
		table.insert(out, stash(table.concat(block, "\n")))
	end
	return table.concat(out, "\n")
end

local function restore(s: string): string
	return (string.gsub(s, OPEN .. "(%d+)" .. CLOSE, function(n)
		return code[tonumber(n) :: number]
	end))
end

-- A table cell's text on one line, with pipes escaped for a GFM table.
local html: (s: string) -> string

local function cell(s: string): string
	return (string.gsub(flat(html(s)), "|", "\\|"))
end

-- An HTML table as a GFM table: the first row is the header.
local function gfm_table(html: string): string
	local rows: { { string } } = {}
	for tr in string.gmatch(html, "<tr[^>]*>(.-)</tr>") do
		local cells: { string } = {}
		for _, body in string.gmatch(tr, "<t([hd])[^>]*>(.-)</t[hd]>") do
			table.insert(cells, cell(body :: string))
		end
		if #cells > 0 then
			table.insert(rows, cells)
		end
	end
	if #rows == 0 then
		return ""
	end
	local width = 0
	for _, r in rows do
		width = math.max(width, #r)
	end
	local lines: { string } = {}
	for i, r in rows do
		for j = #r + 1, width do
			r[j] = ""
		end
		table.insert(lines, "| " .. table.concat(r, " | ") .. " |")
		if i == 1 then
			table.insert(lines, "|" .. string.rep(" --- |", width))
		end
	end
	return "\n\n" .. table.concat(lines, "\n") .. "\n\n"
end

-- Rewrites the HTML in Markdown text (no `<details>` left in it) as Markdown; entities stay
-- encoded until `decode`, so text is decoded once.
html = function(s: string): string
	s = string.gsub(s, "<pre[^>]*>(.-)</pre>", function(body)
		local text = decode((string.gsub(body, "</?code[^>]*>", "")))
		return "\n\n" .. stash("```\n" .. trim(text) .. "\n```") .. "\n\n"
	end)
	s = string.gsub(s, "<code[^>]*>(.-)</code>", function(body)
		local text = decode(body)
		local ticks = if string.find(text, "`", 1, true) then "``" else "`"
		return stash(ticks .. text .. ticks)
	end)
	s = string.gsub(s, "<table[^>]*>(.-)</table>", gfm_table)
	s = string.gsub(s, "<h([1-6])[^>]*>(.-)</h%1>", (function(level: string, body: string): string
		return "\n\n" .. string.rep("#", tonumber(level) :: number) .. " " .. flat(html(body)) .. "\n\n"
	end) :: any)
	-- A linked badge (`<a><picture><img alt></picture></a>`) keeps its alt text as the link text.
	s = string.gsub(s, "<a(%s[^>]*)>(.-)</a>", (function(tag: string, body: string): string
		local text = flat(html(body))
		local href = attr(tag, "href")
		if text == "" then
			return ""
		end
		return if href and href ~= "" then "[" .. text .. "](" .. href .. ")" else text
	end) :: any)
	-- Linked badges sit flush against each other and the text after them.
	s = string.gsub(s, "(%]%([^%)%s]*%))([%w%[])", "%1 %2")
	s = string.gsub(s, "<img(%s[^>]*)>", function(tag)
		local alt = attr(tag, "alt") or ""
		local src = attr(tag, "src") or ""
		if alt ~= "" and (alt ~= "image" or src == "") then
			return alt
		end
		return if src ~= "" then "![" .. alt .. "](" .. src .. ")" else ""
	end)
	s = string.gsub(s, "<br%s*/?>", "  \n")
	s = string.gsub(s, "<hr[^>]*>", "\n\n---\n\n")
	s = string.gsub(s, "<p>", "\n\n")
	s = string.gsub(s, "<p%s[^>]*>", "\n\n")
	s = string.gsub(s, "</p>", "\n\n")
	s = string.gsub(s, "<li>%s*", "\n- ")
	s = string.gsub(s, "<li%s[^>]*>%s*", "\n- ")
	s = string.gsub(s, "</li>", "")
	s = string.gsub(s, "</?[ou]l[^>]*>", "\n\n")
	s = string.gsub(s, "<kbd[^>]*>(.-)</kbd>", "`%1`")
	for _, pair in { { "strong", "**" }, { "b", "**" }, { "em", "*" }, { "i", "*" }, { "del", "~~" }, { "s", "~~" } } do
		s = string.gsub(s, "<" .. pair[1] .. ">(.-)</" .. pair[1] .. ">", function(body)
			local t = trim(body)
			return if t == "" then "" else pair[2] .. t .. pair[2]
		end)
	end
	s = string.gsub(s, "(</?([%a][%w%-]*)[^>]*>)", (function(tag: string, name: string): string
		return if STRIP[string.lower(name)] then "" else tag
	end) :: any)
	return s
end

local function tidy(s: string): string
	s = string.gsub(s, "[ \t]+\n", function(m)
		-- Two trailing spaces are a hard break; keep exactly those.
		return if string.sub(m, -3, -2) == "  " then "  \n" else "\n"
	end)
	s = string.gsub(s, "\n\n\n+", "\n\n")
	return trim(s)
end

-- The `<details>` blocks of `s` at its top level: the text before each, its summary and body, and
-- what follows the last; nested folds stay in their body.
local function split(s: string): { Part }
	local parts: { Part } = {}
	local function text(t: string)
		local md = restore(tidy(decode(html(t))))
		if string.match(md, "%S") then
			table.insert(parts, { kind = "md", text = md })
		end
	end
	local at = 1
	while true do
		local s1, e1, tag = string.find(s, "<details([^>]*)>", at)
		if not s1 then
			break
		end
		-- The matching close: count nested opens.
		local depth, pos, close_s, close_e = 1, (e1 :: number) + 1, nil, nil
		while depth > 0 do
			local o = string.find(s, "<details[%s>]", pos)
			local cs, ce = string.find(s, "</details%s*>", pos)
			if not cs then
				break
			end
			if o and o < cs then
				depth += 1
				pos = o + 8
			else
				depth -= 1
				pos = (ce :: number) + 1
				if depth == 0 then
					close_s, close_e = cs, ce
				end
			end
		end
		local inner = string.sub(s, (e1 :: number) + 1, if close_s then close_s - 1 else #s)
		text(string.sub(s, at, (s1 :: number) - 1))
		local summary = "Details"
		local ss, se, body = string.find(inner, "^%s*<summary[^>]*>(.-)</summary>")
		if ss then
			local head = flat(restore(decode(html(body :: string))))
			-- The summary is drawn as plain text: Markdown marks would show as written.
			head = string.gsub(head, "^#+%s*", "")
			head = string.gsub(head, "%[([^%]]*)%]%([^%)]*%)", "%1")
			head = string.gsub(head, "[*_`]", "")
			if head ~= "" then
				summary = trim(head)
			end
			inner = string.sub(inner, (se :: number) + 1)
		end
		table.insert(parts, { kind = "fold", summary = summary, open = string.find(tag :: string, "%sopen") ~= nil, body = split(inner) })
		if not close_e then
			return parts
		end
		at = close_e + 1
	end
	text(string.sub(s, at))
	return parts
end

-- The parts of a GitHub body in order: Markdown text, and `<details>` folds holding their own parts.
function M.parse(body: string): { Part }
	code = {}
	local s = string.gsub(body, "\r\n?", "\n")
	s = protect(s)
	s = string.gsub(s, "<!%-%-.-%-%->", "")
	local parts = split(s)
	code = {}
	return parts
end

return M
