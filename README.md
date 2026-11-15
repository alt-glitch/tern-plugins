# tern-plugins

Plugins for [Tern](https://stencil.so/tern), Stencil's multiplexing terminal. Each folder is one
plugin package (`plugin.toml` plus Luau), installed on its own.

| Plugin | What it does |
| --- | --- |
| [`prs`](prs/) | Find a pull request, then read, merge or close it in a block beside the pane you are in |

## Install

Install a package on the machine that runs your panes:

```sh
tern plugin install github.com/alt-glitch/tern-plugins/prs
```

`tern plugin install --force …` updates it. To work on a plugin, load it from a checkout instead;
Tern reloads it on every save:

```sh
tern plugin link ./prs
```

## Check

```sh
scripts/check.sh
```

It writes Tern's type definitions into each package (`tern plugin types`) and type-checks the Luau
with [`luau-lsp`](https://github.com/JohnnyMorganz/luau-lsp) when it is on your `PATH`. Tern loads
plugins without type-checking them, so run it before a commit.
