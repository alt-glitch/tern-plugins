--!strict
-- `luau prs/test/markup.test.luau` (scripts/check.sh runs it): the HTML GitHub bodies carry, as
-- review bots and CI reports write it, turned into Markdown and folds.

local markup = require("../lib/markup")

local failed = 0

local function show(v: any, indent: string?): string
	local pad = indent or ""
	if type(v) ~= "table" then
		return string.format("%q", tostring(v))
	end
	local keys = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local lines = {}
	for _, k in keys do
		table.insert(lines, pad .. "  " .. tostring(k) .. " = " .. show(v[k], pad .. "  "))
	end
	return "{\n" .. table.concat(lines, "\n") .. "\n" .. pad .. "}"
end

local function same(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function check(name: string, body: string, want: { any })
	local got = markup.parse(body)
	if same(got, want) then
		print("ok   " .. name)
	else
		failed += 1
		print("FAIL " .. name .. "\n  want " .. show(want) .. "\n  got  " .. show(got))
	end
end

local function md(text: string): any
	return { kind = "md", text = text }
end

local function fold(summary: string, body: { any }, open: boolean?): any
	return { kind = "fold", summary = summary, open = open == true, body = body }
end

check("an empty body has no parts", "  \n<!-- template -->\n", {})

check("plain Markdown passes through", "Fixes the **lint** step.\n\n- one\n- two", { md("Fixes the **lint** step.\n\n- one\n- two") })

check(
	"code keeps its HTML",
	"Use `<details>` here.\n\n```html\n<h2>Title</h2>\n<!-- kept -->\n```",
	{ md("Use `<details>` here.\n\n```html\n<h2>Title</h2>\n<!-- kept -->\n```") }
)

check("angle brackets that are not tags stay", "Returns Vec<String> when a < b.", { md("Returns Vec<String> when a < b.") })

check(
	"a Greptile review: linked badges, a fold whose summary is a heading, small print",
	table.concat({
		"<!-- greptile_summary -->",
		"",
		'<h2><a href="https://app.greptile.com/retrigger?id=1&amp;sig=2"><picture><source media="(prefers-color-scheme: dark)" srcset="https://x/RetriggerDark.svg"><img alt="Retrigger" src="https://x/Retrigger.svg" align="right"></picture></a><a href="https://app.greptile.com/view"><picture><img alt="View in Greptile" src="https://x/View.svg"></picture></a>Confidence Score: 5/5</h2>',
		"",
		"**[Low impact]** The PR appears safe to merge.",
		"",
		"<details><summary><h3>Summary</h3></summary>",
		"",
		"Prepares the code for Ruff preview.",
		"- Evaluation workers read text as UTF-8.",
		"</details>",
		"",
		"<!-- greptile_confidence_score:5 -->",
		"",
		'<sub>Reviews (1) · <a href="https://www.greptile.com/">Reviewed by Greptile</a></sub>',
	}, "\n"),
	{
		md(
			"## [Retrigger](https://app.greptile.com/retrigger?id=1&sig=2) [View in Greptile](https://app.greptile.com/view) Confidence Score: 5/5\n\n**[Low impact]** The PR appears safe to merge."
		),
		fold("Summary", { md("Prepares the code for Ruff preview.\n- Evaluation workers read text as UTF-8.") }),
		md("Reviews (1) · [Reviewed by Greptile](https://www.greptile.com/)"),
	}
)

check(
	"a CI report's HTML table becomes a Markdown table inside its fold",
	table.concat({
		"<details>",
		"<summary>per-job cache results</summary>",
		"",
		"<h3>hits</h3>",
		"",
		'<table><thead><tr><th>Job</th><th>Logs</th></tr></thead><tbody>\n<tr><td>Python tests | 2/3</td><td><a href="https://ci/job/1">view step</a></td></tr>\n</tbody></table>',
		"",
		"<p>Compressed archive bytes.</p>",
		"",
		"</details>",
	}, "\n"),
	{
		fold("per-job cache results", {
			md("### hits\n\n| Job | Logs |\n| --- | --- |\n| Python tests \\| 2/3 | [view step](https://ci/job/1) |\n\nCompressed archive bytes."),
		}),
	}
)

check(
	"folds nest, and `open` starts one unfolded",
	"Before.\n<details open><summary>Outer</summary>\nA\n<details><summary>Inner</summary>\nB\n</details>\nC\n</details>\nAfter.",
	{
		md("Before."),
		fold("Outer", { md("A"), fold("Inner", { md("B") }), md("C") }, true),
		md("After."),
	}
)

check("a fold without a summary is called Details", "<details>\nhidden\n</details>", { fold("Details", { md("hidden") }) })

check(
	"inline HTML marks become Markdown, entities decode once",
	"<b>Bold</b>, <em>it</em>, <code>a &lt; b</code>, <kbd>Esc</kbd><br>next &amp;lt; line",
	{ md("**Bold**, *it*, `a < b`, `Esc`  \nnext &lt; line") }
)

check(
	"an image keeps its alt text as a label, a screenshot becomes an image",
	'<a href="https://x/p1"><img alt="P1" src="https://x/p1.svg"></a> finding\n\n<img width="480" alt="image" src="https://x/shot.png">',
	{ md("[P1](https://x/p1) finding\n\n![image](https://x/shot.png)") }
)

check(
	"an HTML code block becomes a fence",
	"<pre><code>if a &lt; b:\n    run()</code></pre>",
	{ md("```\nif a < b:\n    run()\n```") }
)

if failed > 0 then
	error(failed .. " failed")
end
