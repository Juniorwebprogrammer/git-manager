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
- **Sidebar**: local branches, remotes, tags and stashes, with a filter. Right-click for merge, push, delete (local or remote), push tag, apply/pop/drop stash.
- **Staging & commit**: unstaged/staged lists, stage/unstage/discard per file or all, commit message + description, amend, `Ctrl+Enter` to commit. Merge/cherry-pick conflicts are flagged with an *Abort* option.
- **Diff & code viewer**: unified or side-by-side diffs and a full-file view, with line numbers and syntax highlighting — for local changes and for any commit.
- Shortcuts: `Ctrl+T` new tab, `Ctrl+W` close tab, `Ctrl+Tab` next tab, `F5` refresh, `Esc` close the diff.

**Per-account, without touching your global config.** Every git command run from a workspace uses that account's identity (`GIT_AUTHOR_*` / `GIT_COMMITTER_*`) and its token (sent to `github.com` as an HTTP `Authorization` header via `GIT_CONFIG_*` environment variables, so it never appears in the process list or in any file). You can have two accounts' workspaces open and push from each with the right credentials — no need to press *Connect* first. SSH remotes (`git@github.com:…`) keep using your SSH keys.

## Screens

| Empty state | Accounts list | Account detail |
|---|---|---|
| First launch, no accounts yet — just an "Add account" button. | Cards for each account; the active one is tinted green. | Profile, "Connect", and "Remove account". |

## How account switching actually works

There are two independent things git cares about, and Connect updates both:

1. **Commit authorship** — `user.name` / `user.email` in `~/.gitconfig`. This is what appears as the author of new commits.
2. **HTTPS authentication** — the credentials git uses when you `clone`/`push`/`pull` over `https://github.com/...`. Git Manager manages this via git's built-in `credential.helper store`, which keeps a `~/.git-credentials` file. When you press Connect, any existing `github.com` line in that file is replaced with the active account's token.

Both are **global** (machine-wide), matching how most people actually use two GitHub accounts on one laptop: one account active at a time, switched deliberately.

### Token permissions

When you generate a Personal Access Token at `github.com/settings/tokens`, make sure it has:

- **`repo`** scope (classic token) — required for `clone`/`push`/`pull`, not just for reading your profile.
- **`read:user`** and **`user:email`** — used to fetch your name, avatar, and email for the account card and commit identity.

If you use a **fine-grained token** instead, make sure the repository (or "all repositories") is selected **and** that **Contents** is granted (Read, or Read and write if you plan to push). GitHub's fine-grained tokens separate "see this repo exists" (metadata, granted by default) from "read/write its contents" — missing the latter produces a confusing `403 Write access to repository not granted` error even on a plain `clone`.

## Getting started (run from source)

### Linux

Requirements:

- Flutter 3.x (stable channel) with Linux desktop enabled (`flutter config --enable-linux-desktop`).
- Linux build toolchain: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`.
- `libsecret-1-dev` and `libjsoncpp-dev` (needed to build the secure-storage plugin).

```bash
flutter pub get
flutter run -d linux
```

### Windows

Requirements:

- Flutter 3.x (stable channel) with Windows desktop enabled (`flutter config --enable-windows-desktop`).
- Visual Studio 2022 with the "Desktop development with C++" workload (provides the MSVC toolchain and CMake used to build the native runner).
- [Git for Windows](https://git-scm.com/download/win), on `PATH` — Git Manager shells out to the real `git` binary for `config` and credential storage.

```powershell
flutter pub get
flutter run -d windows
```

## Building the installable package

### Linux (.deb)

```bash
./packaging/build_deb.sh
sudo dpkg -i build/deb/git-manager_<version>_amd64.deb
```

This assembles the release build into `git-manager_<version>_amd64.deb`, which installs:

- The app to `/opt/git-manager`, launched via `/usr/bin/git-manager`.
- An application menu entry ("Git Manager") with the custom icon, installed into the `hicolor` icon theme at 16–512px.
- An **"Uninstall Git Manager"** menu entry — no terminal required. It asks for confirmation, then uses a native password prompt (`pkexec`) to remove the package. Your saved accounts/tokens and git configuration are left untouched.

Runtime dependencies (`libgtk-3-0`, `libsecret-1-0`, `git`, `polkitd`/`policykit-1`) are declared in the package and installed automatically by `apt`/`dpkg` if missing.

### Windows

```powershell
flutter build windows --release
```

This produces `build\windows\x64\runner\Release\`, containing `git_manager.exe` and the DLLs it needs (Flutter engine, `flutter_secure_storage`, `url_launcher`) — copy that folder wherever you want to run it from. There's no installer/uninstaller wired up for Windows yet (unlike the Linux `.deb`); packaging it as an MSIX or an Inno Setup installer is a natural next step if that's needed.

## Architecture

Clean Architecture, one feature module (`accounts`) split into three layers:

```
lib/
  core/
    di/            Riverpod provider wiring (composition root)
    error/          Result<T> / AppFailure (domain-safe errors) and AppException (data-layer)
    theme/          Material 3 theme
    utils/          Avatar color/initials helper
  features/accounts/
    domain/
      entities/     GitAccount — no token, no data-layer concerns
      repositories/ AccountRepository interface
      usecases/     One class per action: AddAccount, GetAccounts, ConnectAccount, RemoveAccount, TestConnection
    data/
      models/       GitAccountModel (carries the token), GitHubUserDto
      datasources/  GitHubRemoteDataSource (API), AccountLocalDataSource (secure storage),
                     GitConfigDataSource (user.name/email), GitCredentialsDataSource (~/.git-credentials)
      repositories/ AccountRepositoryImpl — orchestrates the datasources, maps exceptions to failures
    presentation/
      state/        AccountsNotifier (Riverpod Notifier) + AccountsState
      pages/         AccountsPage, AccountDetailPage
      widgets/       AccountCard, AddAccountCard, AddAccountDialog, AccountAvatar
```

Key decisions:

- The domain `GitAccount` entity never carries the token — only `GitAccountModel` (data layer) does. Presentation code never sees raw tokens.
- `Result<T>` (`Success`/`Failure`) is used instead of throwing across layer boundaries; only the data layer catches `AppException`s and maps them to `AppFailure`s.
- `GitConfigDataSource` and `GitCredentialsDataSource` accept an optional `environmentOverride` (a `HOME`/`USERPROFILE` override) so they can be tested against the real `git` binary without touching the developer's actual `~/.gitconfig` / `~/.git-credentials`.

## Testing

```bash
flutter test
```

Covers:

- Use cases (delegation to the repository).
- `AccountRepositoryImpl`: token validation, duplicate accounts, and — importantly — that `connectAccount`/`removeAccount` correctly drive `GitConfigDataSource` and `GitCredentialsDataSource`.
- `GitConfigDataSource` / `GitCredentialsDataSource`: exercised against the real `git` binary, scoped to a temporary `HOME` directory.
- UI: empty state, add-account success/error, connect, remove (with confirmation), and the active-account green card styling.

## Security notes

- Tokens are stored encrypted via `flutter_secure_storage`, backed by `libsecret` on Linux (the same store used by GNOME Keyring/KWallet) and by Credential Manager (DPAPI) on Windows.
- `~/.git-credentials` (`%USERPROFILE%\.git-credentials` on Windows) is git's own standard mechanism for HTTPS credentials — it stores the active token in **plain text**. On Linux/macOS it's additionally protected with file permissions (`600`), the same trust level as an SSH private key; Windows relies on the user-profile ACLs already covering that directory. This is what GitHub itself recommends for PAT-based HTTPS auth.
- Uninstalling the app does **not** delete your saved accounts, `~/.gitconfig` identity, or `~/.git-credentials` — remove those manually if you want a full cleanup.
