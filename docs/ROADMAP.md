# Roadmap

See where Glimmer is heading before proposing a change. This covers at least the
next year, with no delivery dates or feature promises.

## Next year

Expect work to stay focused on stream quality and a native Mac experience.

| Direction                 | Intended result and evidence                                                                                                                                                              |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wi-Fi fidelity            | Smoother pacing, audio buffering and quality recovery, measured on real streams. [Product principles](https://github.com/Se7enbrc/glimmer/blob/main/PRODUCT.md) and recent release fixes. |
| Clear failures            | A useful next step when a stream fails, with safeguards that recover. [Changelog](https://github.com/Se7enbrc/glimmer/blob/main/CHANGELOG.md).                                            |
| Compatibility             | Keep pace with current Sunshine, macOS and dependencies. [Project rules](https://github.com/Se7enbrc/glimmer/blob/main/AGENTS.md).                                                        |
| Test coverage             | Measure each component and test missing paths before setting a gate. [Security roadmap](SECURITY_ROADMAP.md).                                                                             |
| Parser assurance          | Retain ASan/fuzz results, notices and release-verification evidence. [Security roadmap](SECURITY_ROADMAP.md).                                                                             |
| Reproducibility           | Extend unsigned local comparisons to hosted builds and normalized published artifacts. [Release process](RELEASE.md#4-reproducible-payload).                                              |
| Protocol assessment       | Keep encryption/integrity limits current without requiring a patched Sunshine. [Security model](SECURITY.md).                                                                             |
| Homebrew main cask        | Move beyond the project tap when eligible, keeping a transition period. [Homebrew policy](https://docs.brew.sh/Package-Acceptance-Policy).                                                |
| Apple TV, possibly iPhone | Explore the native engine on Apple TV and consider iPhone, following maintainer direction. These are not available clients.                                                               |

## Out of scope

Keep proposals within these settled product decisions.

| Area             | Boundary                                                                      |
| ---------------- | ----------------------------------------------------------------------------- |
| Mac support      | Apple Silicon, macOS 15.7 or later; no Intel or older-macOS client.           |
| PC software      | Current, unmodified Sunshine; no NVIDIA GameStream or patched-PC requirement. |
| Interface        | SwiftUI/AppKit and system controls; no web views or cross-platform UI.        |
| Rendering        | `AVSampleBufferDisplayLayer`; no Metal renderer.                              |
| Game Mode        | macOS controls it; no private APIs or signed-plist edits.                     |
| Automation       | One Swift command-line implementation in the app binary.                      |
| Business/privacy | Every feature free; no analytics, tracking or unrelated network calls.        |

## How this changes

Open an issue explaining what you want to do and what gets in the way.

The maintainer reviews this direction at least yearly and updates it when a
release changes the plan. Agree on an approach before starting a contribution;
see the [developer guide](CONTRIBUTING.md).
