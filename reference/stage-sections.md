# Which stage reads which profile section

Source for the partials convention (`reference/project-profile.md`): a section only one stage needs is the first to
become a pointer line (`Full text: .claude/issue-workflow/<slug>.md (read when: <stage/step>)`). A section that is a
pointer is followed only when the step needs it. Derived from the "the profile's X" references in the skills.

| Stage | Sections it reads |
|---|---|
| Design | Labels, Sources, Jobs, Design quality, Copy, Default ACs, Screenshots, Prototype, Pattern check, Design feedback, Canvas, Risk areas, Decisions |
| Specify | Sources, Jobs, Risk areas, Default ACs, Screenshots, Verification (sizing), Decisions |
| Build | Branches, Components, Design quality, Pattern check, Design feedback, Copy (Build line), Screenshots, Verification, Pull requests |
| Orchestrate | Labels, Orchestration, Decisions, Pull requests, Risk areas, Design quality |
| Retro | Retro, Context files |

A section that one row alone reads (Prototype: Design; Orchestration: Orchestrate) is the best split candidate; a long
Verification is read by Build and sized by Specify, so its pointer says `read when: Build step 5, Specify sizing`.
