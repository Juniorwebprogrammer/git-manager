<p align="center">
  <img src="assets/icon/app_icon.png" width="120" alt="Git Manager icon" />
</p>

<h1 align="center">Git Manager</h1>

<p align="center">
  Switch between your GitHub accounts — personal, work, whatever — without touching the terminal.
</p>

---

## Why

Switching git identities from the command line (SSH keys, `user.name`/`user.email`, HTTPS credentials) is fiddly and easy to get wrong. Git Manager is a small Linux/Windows desktop app that keeps multiple GitHub accounts on file, verifies each one against the GitHub API, and lets you switch your machine's active git identity with a single **Connect** click.

## Features

- **Add an account** with a GitHub Personal Access Token. The token is validated against the GitHub API (`GET /user`) before it's saved — a "ping" that confirms it actually works.
- **Accounts list** as cards (avatar, name, `@login`); the currently active account is highlighted in green.
- **Account detail** screen with profile info, a link to the GitHub profile, and the **Connect** / **Remove account** actions.
- **Connect** switches your machine's active git identity in one step:
  - Sets `git config --global user.name` / `user.email` to the selected account, so new commits are attributed correctly.
  - Writes the account's token into `~/.git-credentials` via git's `credential.helper store`, so `git clone` / `push` / `pull` over HTTPS stop prompting for a username/password.
- Tokens are stored **encrypted in the OS's native secure storage** (libsecret on Linux, Credential Manager on Windows), never in plain text inside the app's own data.
- Ships as an installable **.deb** package on Linux, with a proper app icon and a GUI **Uninstall Git Manager** entry — no terminal needed for install or removal.

## Projects workspace (GitKraken-style)

Click an account card to open its **workspace**: your projects in tabs (remembered per account), each one with a full git client.

- **Open or clone**: open any local repository, or pick one of your GitHub repositories (listed with the account's token) and clone it.
- **Commit graph**: the history of all branches, remotes and tags drawn as coloured lanes, with branch/tag labels, author, date and SHA. Double-click a label to check it out; right-click a commit to check it out, branch or tag from it, cherry-pick, revert or reset (soft / mixed / hard).
- **Toolbar**: Pull (merge or **rebase**, from the ▾ menu), Push (sets upstream automatically on first push; offers force-with-lease if rejected), Fetch, Branch, Stash, Pop — with ahead/behind counters. Click the branch name to switch branches. The layout adapts to narrow windows (icon-only toolbar, collapsible sidebar, fewer graph columns).
- **Rebase**: rebase the current branch onto any branch, tag or commit, or rebase another branch onto the current one (right-click in the sidebar or the graph), or **drag a branch onto another** in the sidebar to merge or rebase. Local changes are auto-stashed. On conflicts a banner shows the progress (*step 2/5*) with **Continue**, **Skip** and **Abort**.
- **Search** the history by message, author, SHA or branch (`Enter` jumps to the next match).
- **Partial staging**: stage, unstage or discard a single **hunk** from the diff, or click the line gutter to select individual lines (`Shift`+click for a range) and stage / unstage / discard just those.
- **Conflict editor**: conflicted files open side by side — *Current* vs *Incoming* — with *Use current*, *Use incoming*, *Both*, *All current / All incoming* and *Mark resolved*; no external editor needed (diff3-style markers and CRLF files supported).
- **Merge modes**: regular merge, *create merge commit* (`--no-ff`, keeps the merge bubble visible) and *squash* (all changes as one commit), from the sidebar menu or by dragging a branch onto another.
- **Interactive rebase**: right-click a commit (*from here*) or a branch (*onto …*) to reorder commits by dragging and **pick / reword / squash / fixup / drop** each one.
- **GitHub pull requests**: the *Pull requests* section lists the open PRs of `origin` with their CI status (✅ / ❌ / ⏳), lets you check one out (forks included) or open it on GitHub, and the **PR** button creates one from the current branch (pushing it first if needed, optional draft).
- **Pull request view** (click a PR in the sidebar): conversation (description, comments and reviews, with basic Markdown), commits, files changed with their diffs, and CI checks — plus **Merge** (merge commit / squash / rebase, optionally deleting the branch), **Review** (approve / request changes / comment), **Comment**, **Close / Reopen**, **Edit** title and description, and **Checkout**, all without leaving the app. It also says whether the PR can be merged and why not (conflicts, branch protection, draft…).
