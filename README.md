# LC Music Player (LCMP)

LC Music Player is a native music player project focused on a quiet, personal listening experience. It keeps track information unobtrusive and makes playback enjoyable through visualizations such as a graphic equalizer.

The initial release targets macOS. The design aims to keep playback and playlist functionality reusable for a future iPhone version while separating platform-specific UI, audio output, and file access.

## Project status

The project is in its basic-design phase. The current draft and its open questions are in [`docs/basic-design.md`](docs/basic-design.md); [`docs/README.md`](docs/README.md) is the design-document index.

Current agreed direction:

- Select and play local music files and folders without copying the audio files into the app.
- Start with one graphic-equalizer visualization, with room to add and switch visualizations later.
- Keep visualization analysis separate from audio effects; a sound-shaping equalizer is planned for a later phase.
- Remember the app's playback volume per output device and restore it on reconnect. A newly encountered device starts at the current app volume.
- Treat subscription music support as a separate future consideration.

Implementation technologies, supported audio formats, library persistence, and several safety details remain open. See the design document before making assumptions.

## Session knowledge

At the beginning of every work session, read [`LEARNINGS_CODEX.md`](LEARNINGS_CODEX.md) and apply relevant prior findings. The root [`AGENTS.md`](AGENTS.md) records this as a repository working instruction. Add a concise dated entry to `LEARNINGS_CODEX.md` at the end of a session when there are decisions, useful findings, or handoff items to preserve. Do not put credentials or other secrets in this file.

## Git workflow

This repository uses Gitflow-style branches and currently has no remote configured.

- `main` contains release-ready history and version tags.
- `develop` is the integration branch for ongoing work.
- Create `feature/<short-name>` branches from `develop`; merge completed features back into `develop`.
- Create `release/<version>` from `develop` when preparing a release. After validation, merge it into `main`, tag the release, and merge the release changes back into `develop`.
- Use `hotfix/<short-name>` from `main` for urgent fixes to a released version, then merge the fix into both `main` and `develop`.
- Do not commit directly to `main` for ordinary development.

The initial baseline is version `v0.0.1`. No remote URL is set; configure one only when the project owner is ready to publish or collaborate remotely.

## Repository contents

- `docs/` — product and technical design documents.
- `LEARNINGS_CODEX.md` — session findings and handoff notes.
- `AGENTS.md` — repository-specific working instructions for coding agents.
