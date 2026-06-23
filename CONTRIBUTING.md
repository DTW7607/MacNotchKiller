# Contributing

Thanks for improving MacNotchKiller. This project depends on private macOS display APIs, so issues and patches should be reproducible and grounded in real behavior.

[简体中文](CONTRIBUTING.zh-CN.md)

## Development environment

- macOS 13 or later
- Apple Silicon Mac
- Swift 5.10 or later

```bash
git clone https://github.com/DTW7607/MacNotchKiller.git
cd MacNotchKiller
swift build
```

## Reporting issues

Use the repository's Bug Report template. Include at least:

- Mac model and chip
- Full macOS version
- Target app and version
- Whether Accessibility permission has been granted
- Stable reproduction steps
- Complete error text or terminal logs

For display arrangement or input issues, also include the number of external displays and how they are arranged.

## Submitting code

1. Create a short-lived feature branch from `main`.
2. Keep the change focused, and do not include build caches or local configuration.
3. Add comments where lifecycle, coordinate systems, Event Tap behavior, or async callbacks are non-obvious.
4. Run `swift build` and `swift build -c release`.
5. In the pull request, describe the validation environment, expected behavior, and known risks.

Use Conventional Commits when practical:

```text
feat(selection): add interactive window highlighting
fix(display): wait for virtual display registration before positioning
docs: document permissions and recovery shortcut
```

## Engineering constraints

- Do not commit `.build/` or other generated files.
- Do not directly link private class symbols. Private API access must remain behind the narrow bridge layer and runtime checks.
- Do not weaken the `Control + Option + Command + Q` recovery path.
- Do not treat success on one real device as proof of compatibility across macOS versions.
- Do not add telemetry, network requests, or screen upload behavior unless discussed separately and disabled by default.
