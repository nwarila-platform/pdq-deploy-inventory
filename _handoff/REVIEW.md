# Review ledger — pdq role (append-only)

One row per completed strict-cycle piece (merged to `main`). Columns:
`Piece | Summary | P2 verdict | Audited SHA | Proof | Merge SHA | Notes`.

The ledger is the audit trail: every row records what passed P2 (Codex adversarial review) and
P4 (Claude validation + gate + E2E proof) before the `--no-ff` merge. See
`_handoff/loop/STRICT-CYCLE-adapted.md`.

| Piece | Summary | P2 | Audited | Proof | Merge | Notes |
|-------|---------|----|---------|-------|-------|-------|
| P00 | Provision `pdq-dev` VM (full clone of the wsus clean baseline; MAC pinned → IP .181; memory baseline snapshot; 3 disk `eui.*` captured) | n/a (infra bootstrap) | — | port-22 SSH-ready; guest `WIN-2FA90PRKORT` | 574439c | Direct-on-main bootstrap (Codex not yet wired for pdq); shared IP w/ wsus — never run both |
| P01 | Skeleton wiring proof — compose overlays `windows_disk_manager`+`pdq`, both v3.1 loaders resolve, `pdq` validate passes, present is a validated no-op | n/a (bootstrap) | — | **live-VM E2E `ok=23 changed=0 failed=0 skipped=15`** (`-e env=dev`); temp_dir:false honored | (this commit) | Harness proven before any PDQ logic; role cycles P02+ go through the full P0–P5 strict cycle |
