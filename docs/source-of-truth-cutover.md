# Workshop source-of-truth cutover

This record preserves the evidence that Workshop became the hand-authored public
source of truth, including the retired private publisher and public enforcement.

## Final generated state

- Final private source: [`bac452dc2d40ede029d9a30c764dcf7e0c5a20f4`](https://github.com/OMGBrews/devtools/commit/bac452dc2d40ede029d9a30c764dcf7e0c5a20f4).
- Final generated public commit: [`9cae96f386bb9fee65b6f078babb27baff9e83c4`](https://github.com/OMGBrewmaster/workshop/commit/9cae96f386bb9fee65b6f078babb27baff9e83c4).
- Final publisher run [`32387081490`](https://github.com/OMGBrews/devtools/actions/runs/32387081490)
  completed successfully, published no change, and reported that public `9cae96f`
  was current with private `bac452d`.

## First authoritative commit

[`30690c1ded09ede14ed9e070d73d9af486340acb`](https://github.com/OMGBrewmaster/workshop/commit/30690c1ded09ede14ed9e070d73d9af486340acb)
is the first hand-authored Workshop commit. It made the contribution, support,
security, changelog, agent, and definition-of-done guidance authoritative.

## Retired private channel

- The `publish-workshop` workflow was disabled and removed from private devtools.
- Workshop deploy key `160603048` was revoked and private
  `WORKSHOP_DEPLOY_KEY` was removed.
- Private devtools commit [`c6c060350a225200698023a392f041364e9c7b2e`](https://github.com/OMGBrews/devtools/commit/c6c060350a225200698023a392f041364e9c7b2e)
  freezes the legacy compatibility payload for the pilot migration.

## Public enforcement

- Private vulnerability reporting is enabled for Workshop.
- Ruleset [`main requires Workshop checks` (21099180)](https://github.com/OMGBrewmaster/workshop/rules/21099180)
  is active on `branch` refs whose include list is `~DEFAULT_BRANCH` and whose
  exclude list is empty. Its bypass-actor list is empty (`current_user_can_bypass`
  is `never`). Its sole rule requires status context `check`, with strict
  latest-code checking enabled and `do_not_enforce_on_create: false`. GitHub
  displays that context as `Workshop checks / check`.

## Pull-request proof

The deliberate missing-link validation produced a red
[`Workshop checks` run](https://github.com/OMGBrewmaster/workshop/actions/runs/32388227983).
An ordinary merge attempt was refused because the base-branch policy prohibited
the merge. This repaired record is subject to the same required `check` context
and merges only after that check is green.
