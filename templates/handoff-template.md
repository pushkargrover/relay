# Context Handoff
**Generated:** YYYY-MM-DD HH:MM:SS
**Project Directory:** C:\path\to\project
**Handoff File:** C:\path\to\handoffs\handoff-YYYY-MM-DD-HHMMSS.md

## Session Goal
One to three sentences describing what the user was trying to build, fix, or accomplish in this session.

## Decisions Made
- **Decision:** [what was decided] — **Rationale:** [why this approach was chosen over alternatives]
- **Decision:** [what was decided] — **Rationale:** [why]

## Work Completed

### Files Created or Modified
- `path/to/file.ts` — Created. Implements X to solve Y.
- `path/to/other.ps1` — Modified. Added Z function, changed A to B.

### Commands Run
- `npm install foo` — Added dependency for X feature
- `git commit -m "..."` — Committed work through phase 1

## Current State
What is working right now. What the code/system does. Whether tests pass. The last thing attempted and its outcome.

## Open Questions / Blockers
- [ ] How should we handle edge case X?
- [ ] Unclear if library Y supports feature Z — needs investigation
- [ ] Waiting on user decision about approach A vs approach B

## Next Steps
1. Fix the failing test in `path/to/test.ts` — the mock for X is not set up correctly
2. Implement the Y feature in `path/to/feature.ts`
3. Run `npm test` to verify all tests pass
4. Update README with new API documentation

## Key File Paths
- `path/to/main.ts` — Entry point, start here
- `path/to/config.ts` — Configuration schema, read before touching anything
- `path/to/types.ts` — Shared type definitions used everywhere

## Instructions for Next Agent
- This project uses tabs not spaces — the linter enforces it
- The `foo` command requires VPN to be active
- Do not modify `legacy-module/` — it is intentionally frozen
- The user prefers explicit error handling over silent failures
- Run `npm run build` before running tests — the test suite depends on compiled output
