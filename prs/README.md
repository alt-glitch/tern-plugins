# prs

A Tern block for browsing pull requests. It has two lists: **Yours** (your open pull requests)
and **Review requested** (open pull requests waiting on your review). Each list is grouped by
repository, with the most recently updated repository and pull request first. Both lists come
from the GitHub CLI and refresh every two minutes.

<img src="docs/review-requested.png" alt="The Review requested tab: pull requests in NousResearch/hermes-agent with each author's initials and handle and how long ago each was updated" width="480">

## Open it

- **Pull requests** in the command palette (⌘K), or
- ⌥⇧⌘P.

The block opens to the right of the focused pane. If one is already open in the window, Tern
focuses it instead, because each open block polls GitHub.

## Find a pull request

Type to filter the current list. The filter matches the title, the repository, the number and
the author, and shows the matched part of the title in bold. Enter opens the selected pull
request on GitHub.

Filtering Review requested by title finds
[NousResearch/hermes-agent#155575](https://github.com/NousResearch/hermes-agent/pull/155575):

<img src="docs/filter-by-title.png" alt="The filter 'browser design' leaves one row: feat(desktop): add native Browser Design Mode #155575, with the matched words in bold" width="480">

Filtering Yours by number finds
[NousResearch/hermes-agent#151819](https://github.com/NousResearch/hermes-agent/pull/151819):

<img src="docs/filter-by-number.png" alt="The filter '151819' leaves one row: fix(usage): provider limits first, Nous balance apart #151819" width="480">

Clearing the filter keeps the selection on the same pull request.

Yours leaves out the author column, because every row there is you:

<img src="docs/yours.png" alt="The Yours tab: your open pull requests in NousResearch/hermes-agent, newest first, with the Drafts toggle on" width="480">

## Keys

| Key | Does |
| --- | --- |
| type | Filters by title, repository, number or author |
| ↑ ↓, Page Up/Down, Home/End | Move |
| Enter, or double-click | Opens the pull request on GitHub |
| Tab, Shift+Tab | Switches between Yours and Review requested |
| Esc, ctrl+u | Clears the filter |
| ctrl+r | Refreshes now |
| ctrl+d | Shows or hides drafts (remembered across restarts) |

## Needs

The block runs `gh search prs` on the machine that runs your panes, so install the
[GitHub CLI](https://cli.github.com) there and sign in with `gh auth login`. If `gh` is missing or
signed out, the block says so and offers a refresh:

<img src="docs/signed-out.png" alt="The error card: The GitHub CLI is not signed in. Run gh auth login in a shell on this machine, then refresh." width="480">

If a later refresh fails, the block keeps the last list and shows the problem above the buttons,
where it otherwise shows when the list was last updated.
