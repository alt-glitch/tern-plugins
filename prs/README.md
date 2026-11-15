# prs

A Tern block for browsing pull requests. It has two lists: **Yours** (your open pull requests)
and **Review requested** (open pull requests waiting on your review). Each list is grouped by
repository, with the most recently updated repository and pull request first. Both lists come
from the GitHub CLI and refresh every two minutes.

## Open it

- **Pull requests** in the command palette (⌘K), or
- ⌥⇧⌘P.

The block opens to the right of the focused pane. If one is already open in the window, Tern
focuses it instead, because each open block polls GitHub.

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
signed out, the block says so and offers a retry. If a later refresh fails, it keeps the last list
and shows the problem under it.
