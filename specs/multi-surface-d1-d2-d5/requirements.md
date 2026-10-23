# multi-surface-d1-d2-d5 — Requirements

> Written for round 3, after the round-2 Intent gate (G1) failed this change for having no acceptance table.
> The change bundles three roadmap items (ACTION-PLAN D1, D2, D5) that were merged ungated and then gated together.

## Done means

The gate agents (D1) and the model map (D2) exist, agree with each other and with the gate cards, and cannot
write files by name; and `PIPELINE_DATA` (D5) moves a project's `project/`, ledger, dashboard and reports away
from the kit's code, with every tool, hook and installer reading the same directory, refusing a value that
points at another project, and never judging this repository by another project's rules.

Nothing here claims the model IDs are current: that cannot be verified offline (see criterion 6).

## Acceptance criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | One subagent per gate G1..G8 exists in `templates/agents/` and `.claude/agents/`, identical, each with an explicit `tools:` or `disallowedTools:` list that grants no file-writing tool by name | `test_gate_agents_have_explicit_tool_lists_and_none_can_write_by_name`; the agents-in-step tests in `tests/run.sh` |
| 2 | `project/models.conf` is the single place a tier's model ID is edited; the kit's agent `model:` lines must equal it | the models.conf drift test in `tests/run.sh` (grep `models.conf`) |
| 3 | `PIPELINE_DATA` unset changes nothing; set, it redirects the ledger, surfaces, dashboard, reports and `commands.conf` in `ledger.sh`, `status.sh`, `reconcile.sh`, `dashboard.sh`, `mine-registry.sh`, both installers, the R0c and Stop hooks and the pre-push hook | `test_pipeline_data_redirects_ledger_and_status`, `test_status_reads_the_ledger_and_dashboard_from_the_data_directory`, `test_evidence_cmd_reads_commands_conf_from_the_data_directory`, `test_reconcile_and_r0c_read_the_data_directorys_surfaces`, `test_pre_push_enforces_the_data_directory_surfaces_and_reports`, `test_stop_hook_reads_the_data_directory_ledger` |
| 4 | A `PIPELINE_DATA` that is relative, missing, outside the repository, or contains a character that cannot be baked into a hook is refused (exit 2; pre-push BLOCKS; the Stop hook fails open with a message); `PIPELINE_DATA_EXTERNAL=1` waives only containment | `test_data_root_check_accepts_inside_and_refuses_everything_else`, `test_every_tool_refuses_a_pipeline_data_from_another_project`, `test_pre_push_blocks_when_pipeline_data_is_outside_the_repo`, `test_claude_hooks_say_so_when_pipeline_data_is_unusable`, `test_pre_push_inline_check_refuses_the_characters_data_root_sh_refuses` |
| 5 | The installed hooks enforce the data directory the installer validated, whatever the pusher's environment holds, and the dashboard the hook regenerates uses it too | `test_installed_pre_push_has_the_data_directory_baked_in`, `test_pre_push_exports_the_baked_data_directory_to_dashboard_sh`, `test_install_claude_hook_bakes_pipeline_data_into_both_commands`, `test_install_claude_hook_refuses_a_rerun_with_a_different_pipeline_data`, `test_install_hook_normalises_a_trailing_slash_and_status_reports_the_baked_directory` |
| 6 | "Do not hard-code a model about to be retired" is read as: model IDs live in ONE edit place (`project/models.conf`), a drift test fails when the kit's copies disagree, and each row records the date it was last checked. It is NOT read as "the IDs are current today": that needs the network, and the CHANGELOG says so | the drift test (criterion 2); the `checked <date>` text on each `models.conf` row; the CHANGELOG entry |
| 7 | The data directory's own files (ledger, dashboard, reports) are not tiered as project work, but only when the data directory is in THIS repository; a foreign data directory's prefix never hides this repository's files | `test_reconcile_does_not_tier_the_data_directory`, `test_reconcile_excludes_only_a_data_directory_in_this_repository` |
| 8 | The files that decide all of this are themselves routed T4 in this repository's `project/surfaces.conf`, including `tools/lib/data-root.sh` | `test_the_kits_own_surfaces_route_data_root_sh_as_t4` |

## Out of scope (accepted, in `project/risks.md` R-012)

`.install-base` stays in the kit directory; installed agents' `model:` lines can drift from `models.conf`; G4-G7 have
Bash; no Linux or macOS evidence yet.
