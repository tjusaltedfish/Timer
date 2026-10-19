# Timer development

Read `docs/STATUS.md` for implemented behavior and `docs/HANDOFF.md` for remaining requirements. Current visual decisions are in `docs/design/ink-system.md`.

## Shared environment (Codex and Claude)

- The checkout may move; derive paths from the repository root. Never assume the previous Chinese directory exists.
- Before validation after switching tools, run `./tools/setup-dev.ps1`. This restores missing dependencies **without changing `pubspec.lock`**.
- Use `./tools/setup-dev.ps1 -Clean` once after moving the checkout, or when generated build metadata proves it still contains old paths. Routine switches do not need cleanup.
- `tools/toolchain.json` pins Flutter/Dart. `tools/dev-environment.ps1` selects the one shared SDK, Android SDK, Java and Pub cache. Do not install another SDK, upgrade it, or delete SDK/Pub caches to fix a missing package.
- Shared root: `%USERPROFILE%/DevTools/Timer`. SDK: `toolchains/flutter`; Pub cache: `pub-cache`; Android: `toolchains/android-sdk` beneath that root. AppData paths can be redirected by the Store-packaged Codex app and must not be used for shared toolchains.
- For direct commands, dot-source `tools/dev-environment.ps1`, then use `$taskEnv = Initialize-PlannerEnvironment` and `$taskEnv.Flutter`. Run Flutter commands in `apps/planner`.
- Backend commands use `server/.venv/Scripts/python.exe -m ...`, including pip/pytest/uvicorn. Do not change the research Python environment.
- Native builds use `tools/build-windows.ps1` and `tools/build-android.ps1`; native integration uses `tools/test-desktop.ps1` with an isolated fixture.

## Verification and data

- Run backend pytest, Flutter tests and analyze for changes affecting them. Keep real results and unverified device behavior distinct.
- Keep SQLite data, archives, API keys, pairing tokens, signing keys, local environments and build output out of Git. Test fixtures use isolated temporary data; never upload user data.
- Preserve accepted product work from both assistants. Make focused commits; do not replace existing user changes while fixing tooling.
