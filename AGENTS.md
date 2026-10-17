# Repository working instructions

- At the start of every session, if the local-only `LEARNINGS_CODEX.md` exists, read it in full and apply relevant decisions, findings, and handoff notes before changing files.
- At the end of a session, append a concise dated entry to the local-only `LEARNINGS_CODEX.md` when it exists and the session produced useful findings, decisions, or follow-up work. Preserve earlier entries; do not rewrite the history. Never add this file to Git.
- Never record credentials, access tokens, or other secrets in repository documentation or session notes.
- Keep agreed target product specifications in `docs/design/00_basic-design.md` and implemented structures and behavior in the relevant design documents under `docs/`.
- Follow the document structure and writing style described in `docs/README.md`.
- Record major design and implementation decisions with their reasons in the project management tool's decision log (`decisions`), not in the repository.
- Keep work-in-progress status, working history, unresolved questions, validation results, and ticket handoffs in the local-only `DEVELOPMENT_NOTES.md`. Read it when it exists before changing the design or continuing ticket work. Preserve earlier records, append dated updates, and never add this file to Git.
- Do not put ticket-specific scope, implementation schedules, or development history in design documents. Reusable verification procedures may remain with the implemented design; record their execution results in `DEVELOPMENT_NOTES.md`.
