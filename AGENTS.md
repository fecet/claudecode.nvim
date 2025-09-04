# Repository Guidelines

## Project Structure & Module Organization
- `lua/claudecode/`: Core plugin modules (entry: `lua/claudecode/init.lua`).
- `plugin/claudecode.lua`: Load guard and optional auto-setup (requires Neovim ≥ 0.8.0).
- `tests/`: Busted tests with `unit/` and `integration/`; bootstrap in `tests/busted_setup.lua` and `tests/minimal_init.lua`.
- `fixtures/`: Runnable Neovim configs for manual testing; `source fixtures/nvim-aliases.sh` then `vv oil`, `vv nvim-tree`, etc.
- `scripts/`, `Makefile`, `flake.nix`: Dev helpers, tasks, and Nix-based tooling.

## Build, Test, and Development Commands
- `nix develop`: Enter dev shell with all dependencies (recommended).
- `make check`: Lua syntax check + `luacheck` over `lua/` and `tests/`.
- `make format`: Format via treefmt/Stylua.
- `make test`: Run `busted` with coverage; respects `LUA_PATH` setup.
- `nvim -u tests/minimal_init.lua`: Launch minimal runtime for local plugin testing.
- `make help`: List available tasks.

## Coding Style & Naming Conventions
- Indent: 2 spaces; max line width 120; prefer double quotes; always use call parentheses (see `.stylua.toml`).
- Formatter: Stylua (via `make format`); treefmt integrates Nix formatters.
- Lint: `luacheck` configured in `.luacheckrc` (`luajit+busted` std). Place modules under `claudecode.*` namespace.

## Testing Guidelines
- Framework: `busted` + `luassert` + `luacov`.
- Location & names: `tests/unit/**` and `tests/integration/**`; use `*_spec.lua` or `*_test.lua`.
- Run a single file: `busted tests/unit/diff_spec.lua -v` (or `make test` for all).
- Keep tests hermetic; reuse helpers from `tests/busted_setup.lua`.

## Commit & Pull Request Guidelines
- Messages: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `chore:`); add scope when helpful (e.g., `feat(terminal): …`).
- PRs must include: clear description (what/why), validation steps, linked issues (e.g., `#123`), and screenshots/GIFs for user-visible changes.
- Update docs (`README.md`, `ARCHITECTURE.md`, `PROTOCOL.md`) when behavior or interfaces change. Ensure `make` passes locally before review.

## Security & Configuration Tips
- The server binds to `127.0.0.1` and uses an auth token; never commit lockfiles or tokens (e.g., `~/.claude/ide/*`).
- Use `make clean` to remove coverage artifacts.

