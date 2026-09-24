# Contributing

Thanks for helping improve Microphone Choice.

1. Check existing issues before opening a new one.
2. For a bug, describe the steps to reproduce it, your macOS version, the Bluetooth device type, the expected result, and the actual result. Remove private identifiers from logs or screenshots.
3. Keep pull requests focused. Explain the behavior change and how you tested it on a Mac.
4. Run `./scripts/package-release.sh` before opening a pull request. Check that `--probe` runs from the built app. For changes to the connection prompt, test a real connect or reconnect flow and include a screenshot.
5. The project is MIT licensed. By contributing, you agree that your contribution is distributed under that license.

The app is deliberately small. Changes that improve connection detection, microphone selection, accessibility, and installation are especially useful.
