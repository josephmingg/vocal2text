# Notes for Claude

## CI and GitHub Actions minutes

The owner builds and runs Vocal locally (`make install`), so CI is not needed on
every push, and GitHub Actions minutes are limited (macOS jobs cost the most).

- End every commit message with `[skip ci]` on its own line, before the
  attribution trailers. GitHub then starts no workflow for that commit, on
  either the push or the pull request.
- Before pushing, check locally instead: build and run the Linux test suite
  (`swift build --build-tests && swift test` in the `swift:6.0-noble` image CI
  uses) and SwiftLint, and say what you ran.
- Run CI only when the owner asks, for example before a merge. Start it with
  the workflow's manual trigger (`workflow_dispatch` on `ci.yml`), not an empty
  commit.
- If a run starts anyway, cancel it unless the owner asked for it.
- Merging is not needed to use the app: it builds from the local checkout.
