fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios signing_bootstrap

```sh
[bundle exec] fastlane ios signing_bootstrap
```

One-time/renewal: create the shared App Store cert + profiles, push to match storage

### ios ci_signing

```sh
[bundle exec] fastlane ios ci_signing
```

Every build: fetch signing assets read-only and switch both targets to manual signing

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
