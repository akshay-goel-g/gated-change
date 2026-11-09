# Coupling registry

> Yours. The curated registry — the one gates actually read.
>
> `tools/mine-registry.sh` writes **candidates** to `registry-draft.md`. This file holds
> only what survived. The draft is disposable; this is not.

Universal couplings (auth → session invalidation, migrations → rollback, quotas →
enforce-at-write, and the rest) live in `core/03-registry.md` and apply automatically. Do
not copy them here — record only what is true of *this* codebase.

---

## The shape of an entry

> **If you touch X, you must also check Y — because Z happened.**

The **because** is the whole value. "They are related" gets skimmed past; "the allow rule is
evaluated above the block rule" gets checked.

## The bar for inclusion

1. Could this have been caught by asking one question before the change?
2. Is that question **non-obvious** to someone competent reading the code?
3. Can you name the incident that proves it?

Three yeses, it is an entry. Fewer, it is a code comment.

**Delete anything you cannot explain.** One unexplained rule teaches everyone to skim, and a
skimmed registry is worse than no registry — it costs the same attention and returns nothing.

---

## Entries

| If you touch… | You must also check… | Because |
|---|---|---|
| the `confidence` vocabulary — `ledger.sh`'s accepted values (incl. the `cmd_add` write-side guard: `fresh\|low` closed set, and **required for a `pass`/`fail` verdict**), a gate card's `logs_with:` line, or `04-ledger.md`'s definition | `tools/dashboard/app.js`'s `isIndependent()` (and `cmd_report` / `cmd_gates`'s literal `grep -c '"confidence":"fresh"'` / `"low"`), plus any tool-emitted `ledger.sh add` command string (`cmd_compliance`'s remediation hints) | `isIndependent()` is a strict `=== "fresh"` allow-list — a value it does not recognise silently renders a real fresh-context review as an author self-check and drops it from the fresh/low/challenge-rate counts. `ci-to-codebuild` G7 round 2 logged `--confidence true` (`pass`, challenged) and it vanished from the disagreement quota until a corrected append (commit `b471896`, 2026-09-08). The vocabulary is duplicated across `ledger.sh` (write guard **and** the `add` hints it prints), all 8 gate cards, `04-ledger.md`, and `app.js`; changing one without the others is the failure. |
| the `PIPELINE_DATA` data directory: `tools/lib/data-root.sh` (`data_root_check`), the inline copy in `templates/pre-push`, `coverage_data_prefix`, or the data-directory exclusion in `tools/reconcile.sh` and `coverage_scan` | every other consumer of the data directory — `ledger.sh`, `status.sh`, `dashboard.sh`, `mine-registry.sh`, `update-kit.sh`, both installers, `r0c-post-edit.sh`, `stop-compliance.sh` — and the `plugin/kit/` mirror of each | They must all agree on WHICH directory and on what counts as inside the repository. Reverting one passed every test in round 2 of the D1/D2/D5 gates; `<repo>/..` passed the containment walk in round 3 (G7); and the exclusion once dropped code in a shared data directory from tiering (G6). The bug categories map to `test_dashboard_from_an_absolute_data_path_does_not_depend_on_the_checkout_location` (a checkout-specific or GIT_DIR-dependent value in the committed dashboard), `test_data_root_check_and_the_pre_push_copy_refuse_dotdot_and_symlinks_that_leave_the_repository`, `test_the_data_directory_exclusion_covers_only_what_the_pipeline_writes`, `test_every_tool_refuses_a_pipeline_data_from_another_project` and `test_ledger_and_status_agree_on_the_ledger_from_the_same_cwd_with_pipeline_data_unset`; the exported-`GIT_DIR` category to `test_containment_cannot_be_fooled_by_an_exported_git_dir` and `test_the_data_directory_prefix_is_found_even_when_git_dir_is_exported`; the linked-worktree category to `test_evidence_and_citations_are_judged_in_the_working_tree_not_the_data_directorys_checkout` and `test_the_stop_hook_judges_the_working_tree_not_the_data_directorys_checkout`; the nested-repository category to `test_a_data_directory_inside_a_nested_repository_is_refused_by_both_copies`; the kit-as-its-own-repository layout to `test_the_kit_as_its_own_repository_contains_and_redirects_pipeline_data`; round 10's inherited `WORK` in the Stop hook to `test_the_stop_hook_ignores_a_work_variable_from_the_environment`; the data prefix judged by toplevel instead of git common dir to `test_reconcile_from_a_linked_worktree_excludes_the_main_checkouts_data_directory_files` and `test_coverage_data_prefix_is_the_same_from_a_linked_worktree`; a Claude hook command with no baked value to `test_a_claude_hook_with_no_baked_value_is_reported_when_the_shell_exports_one`; bare `git` in the mismatch helpers under an exported `GIT_DIR` to `test_data_root_hook_mismatch_finds_the_repository_without_the_callers_git_environment`; a hostile value echoed to the agent to `test_r0c_never_echoes_a_hostile_data_directory_to_the_agent` and `test_the_stop_hook_never_echoes_a_hostile_data_directory`; the hooks judging the data directory from their own working directory instead of the project to `test_the_stop_hook_checks_the_data_directory_from_the_project_not_from_its_working_directory` and `test_r0c_checks_the_data_directory_from_the_project_not_from_its_working_directory`. |

---

## Retired entries

Keep them, with the date and the reason. A coupling that stopped being true because the
design changed is useful history; silently deleting it invites someone to re-derive the same
rule from the same old incident.

| Entry | Retired | Why it no longer holds |
|---|---|---|
| | | |
