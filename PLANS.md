# PLANS.md

Use this file for tasks that are large, risky, or likely to span multiple
rounds.

Create or update a plan before major edits when the task:
- Touches Noise, BLE, mesh, or database internals
- Changes behavior across multiple files or layers
- Needs phased verification
- Requires careful rollback or migration thinking

Keep plans concrete. Avoid filler.

## Plan Template

```md
# <task title>

## Goal
- What outcome is required?

## Constraints
- Repo invariants
- User constraints
- Tooling or environment limits

## Facts
- What is already true in the codebase?
- What was verified from docs, tests, or logs?

## Approach
- Chosen implementation path
- Why this path over obvious alternatives

## Steps
1. First concrete change
2. Next concrete change
3. Verification step

## Verification
- `flutter analyze`
- Targeted `flutter test ...`
- Full suite if warranted
- Manual checks if needed

## Risks
- What could regress?
- What remains uncertain?

## Open Questions
- Questions that must be answered before proceeding
```

## Update Rules

- Update the plan when facts change.
- Mark completed steps explicitly.
- Remove stale assumptions.
- Keep the plan short enough to stay usable.

## Closeout

Before finishing a multi-step task:
- Reconcile plan steps against the actual result
- Note any skipped verification
- Call out remaining risks
