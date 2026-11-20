# Contributing

Thanks for helping. A few things keep the app safe to point at real robots:

- **Robot motion only through the assistant's validated skills and the session controllers** (STOP > person >
  assistant). Anything the robot sends to the phone is displayed, never executed.
- **No keys in the app or the repository.** The online assistant reaches a model through `tool/agent_proxy.py`,
  which reads its key from a file or the environment.
- Before a pull request: `flutter analyze lib test tool` (no issues) and `flutter test` (all pass).
  If you touch driving, navigation or the assistant, say which live test you ran (`tool/live_*.dart`, through
  `scripts/dev-env/sim_live_test.sh`).
- Pin new dependencies to versions published at least two weeks ago.
- User-facing text goes through `lib/l10n/app_en.arb` (and the other languages if you can).

By contributing you agree your contribution is licensed under the Apache License 2.0.
