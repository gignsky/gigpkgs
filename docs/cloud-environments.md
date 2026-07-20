# Claude Code cloud environments for gigpkgs

Settings for [Claude Code on the web](https://code.claude.com/docs/en/claude-code-on-the-web)
cloud environments used to develop `gigpkgs` and other Nix / Rust / Python /
Nushell projects.

Two environments:

| Environment | Purpose | Setup script |
| :---------- | :------ | :----------- |
| **buzz**   | `gigpkgs` + general Nix / Rust work. Pre-warms the gigpkgs devShell. | [`docs/cloud/buzz-setup.sh`](cloud/buzz-setup.sh) |
| **bumble** | Repo-agnostic polyglot runner: Nix + Rust + Python + Nushell. | [`docs/cloud/bumble-setup.sh`](cloud/bumble-setup.sh) |

The scripts are kept in-repo as the source of truth. To apply them you copy the
script text into the environment's **Setup script** field in the web UI — cloud
environment config (setup script, env vars, network access) lives in the
Anthropic account, not in the repo, so it can't be auto-injected from here.

## How a cloud environment is configured

Each session runs in a fresh, isolated Anthropic-managed VM with the repo
cloned. An *environment* carries three configurable things, all edited from
`claude.ai/code` (environment selector → hover → settings icon; or **Add
environment**):

1. **Network access** — `None` / `Trusted` / `Full` / `Custom`. Default is
   `Trusted` (a fixed allowlist of package registries + GitHub + cloud SDKs).
2. **Environment variables** — `.env` format, one `KEY=value` per line, no
   quotes. No secrets store yet, so treat them as visible to anyone who can
   edit the environment.
3. **Setup script** — a Bash script that runs **as root on Ubuntu 24.04**,
   once, before Claude Code launches.

### Caching (why the setup script is the right place for Nix)

After the setup script finishes, Anthropic snapshots the filesystem and reuses
that snapshot for later sessions — the script is then skipped. So the `/nix`
store that our script builds (Nix itself, flake inputs, pre-warmed devShell
packages) is baked into the snapshot and present at the start of every new
session. Files persist; running processes do not. Cache rebuilds when you
change the setup script or allowed hosts, or after ~7 days.

Keep the script under ~5 minutes so the cache can build. Ours stays well under
that; the gigpkgs devShell pre-warm in `buzz` is bounded by `timeout 300 … ||
true`, so it can never block session start (a partial warm is still cached).

### What the base image already provides

Do **not** reinstall these — the cloud image ships them:

- **Rust:** `rustc`, `cargo` (but *not* clippy / rustfmt / rust-analyzer —
  `bumble` adds those).
- **Python 3.x:** `pip`, `poetry`, `uv`, `black`, `mypy`, `pytest`, `ruff`.
- Node (20/21/22 via nvm), Go, Java, Ruby, PHP, C/C++, Docker, PostgreSQL 16,
  Redis 7, plus `git`, `jq`, `yq`, `ripgrep`, `tmux`.

**Missing, and what our scripts add:** Nix, flakes, `direnv` / `nix-direnv`,
and Nushell.

## Network access

`Trusted` is sufficient for both environments — **no `Custom` allowlist is
needed**. The default allowlist already includes everything the scripts and
flakes reach:

- `*.nixos.org` → `cache.nixos.org`, `releases.nixos.org`, `channels.nixos.org`
  (Nix binary cache + channels, and the **installer**, see the gotcha below).
- `crates.io`, `static.crates.io`, `index.crates.io` (Rust).
- `pypi.org`, `files.pythonhosted.org` (Python).
- `github.com` + `codeload.github.com` + `raw.githubusercontent.com` (flake
  inputs: `nixos-unstable`, `nixos-26.05`, `home-manager`, `git-hooks.nix`,
  `fupdate`).

Use **Custom** (with *"include default package managers"* checked) only if you
add a personal binary cache — e.g. a Cachix cache — which would need
`*.cachix.org` and `cachix.org` added to the allowlist. The current
`flake.nix` declares no extra substituter, so `Trusted` is enough today.

### Gotcha: the bare `nixos.org` apex is blocked

The default allowlist entry is `*.nixos.org`, and that wildcard matches
**subdomains only**, not the apex `nixos.org`. The standard installer one-liner
`curl -L https://nixos.org/nix/install` therefore fails at the egress proxy
with `curl: (22) ... 403` / `CONNECT tunnel failed, response 403`, which then
cascades into `/root/.nix-profile/etc/profile.d/nix.sh: No such file or
directory` because Nix never got installed.

The setup scripts avoid this by fetching a **pinned** installer straight from
`releases.nixos.org/nix/nix-<version>/install` (a subdomain, allowed). That
installer downloads its tarball from `releases.nixos.org` and Nix then pulls
from `cache.nixos.org` — all subdomains, none touch the blocked apex. Bump the
`NIX_VERSION` value at the top of the install block (or set a `NIX_VERSION`
environment variable) to upgrade; find current versions by browsing
<https://releases.nixos.org/?prefix=nix/>.

(If you would rather run the vanilla one-liner, the alternative is to switch
the environment to **Custom** network access, keep the defaults, and add
`nixos.org` to the allowlist. The pinned-installer approach keeps `Trusted`
working with zero network changes, so the scripts use that.)

## TLS / proxy — already handled

All outbound HTTPS goes through the session's egress proxy, and the
environment already pre-sets `HTTPS_PROXY`, `NIX_SSL_CERT_FILE`, `SSL_CERT_FILE`
and friends, with the proxy CA already in the system trust store. That is why
the scripts install Nix **single-user / daemonless** (`--no-daemon`): builds
run as root and inherit those variables, so substituter fetches succeed. A
`nix-daemon` would run in its own environment without them and its downloads
would fail behind the proxy.

## Environment variables

None are required — `/etc/nix/nix.conf` (written by the setup script) carries
the flakes settings, and TLS/proxy vars are pre-set. Optional niceties, in
`.env` format:

```text
DIRENV_LOG_FORMAT=
```

(An empty `DIRENV_LOG_FORMAT` silences direnv's per-command banner.)

## Using the tools in a session

The setup script symlinks the Nix profile into `/usr/local/bin`, so `nix`,
`direnv`, `just` and `nu` are on `PATH` for Claude's (non-login) shells.

- **gigpkgs / any flake project:** run devShell tools through the flake so you
  get the exact pinned versions and the repo's custom packages:

  ```bash
  nix develop -c just            # the repo's justfile menu
  nix develop -c nixfmt .        # formatter from the devShell
  nix develop -c statix check    # linter from the devShell
  ```

  On `buzz` this devShell is pre-warmed into the snapshot, so it activates
  fast.

- **Ad-hoc / repo-agnostic (bumble):** `nu`, `cargo`, `rustc`, `clippy`,
  `cargo fmt`, `rust-analyzer`, and the base Python stack are directly on
  `PATH`; per-project pins come from each repo's own `nix develop -c`.

## Applying changes

1. Open `claude.ai/code`, click the environment selector.
2. **buzz:** hover → settings icon → paste `docs/cloud/buzz-setup.sh` into
   *Setup script*, confirm network access is `Trusted`, save.
3. **bumble:** **Add environment**, name it `bumble`, paste
   `docs/cloud/bumble-setup.sh`, set network access `Trusted`, save.
4. Start a fresh session in each so the setup script runs and the cache builds.
   Ask Claude to run `check-tools`, `nix --version`, and `nu --version` to
   confirm.
