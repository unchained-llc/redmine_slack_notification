# Implementation review

The feature examples use fictional data and selected supported configuration. They do not imply that every optional field is enabled by default. UI typography and spacing are illustrative; content and operations are checked against the source below.

| Illustration | Implementation source | Required constraints |
| --- | --- | --- |
| Event notifications | `Formatter.build_issue_payload`, `build_wiki_payload`, `build_generic_payload`, `TimeEntryPatch` | Purple attachment line by default; actual event labels, time-entry ID and hours metadata; no extra source buttons. |
| Notification formatting | `Formatter.build_issue_payload`, `body_diff_blocks`, `change_field_blocks`, `metadata_fields` | Description diff, Changes and Metadata sections; optional metadata shown as fields. |
| Channel routing | `README.md` channel inheritance section; YAML example | Configuration example, not a settings GUI; own project, nearest ancestor, then global fallback. |
| Work Object previews | `Formatter.with_issue_work_object`, `issue_work_object_details` | Preview fields can be configured; native detail fields and configured actions; no invented app navigation. |
| Issue actions | `WorkObjects.edit_modal` | Description, status, priority, assignee, due date, comment in source order; permission-dependent fields. |
| Comment threads | `Formatter.build_journal_payload` | Initial comment notification; subsequent threaded payload uses a simple issue heading and body rather than another full card. |
| Imported replies | `ThreadComments.persist_reply`, `LinkQuotes.import`, `LinkCards.render_card` | Reply quote only; omit parent and Thread reply label for automatic import. |
| Slash commands | `SlashCommands.issue_list_payload`, `Formatter.due_digest_attachment` | Subject search results use bullet links, project and due timing; no status badges or extra result actions. |
| Message-to-issue | `MessageShortcuts.interaction`, `select_project`, `SlashCommands.modal` | Separate project selector and New issue form; second form has tracker, subject and description; Save button. |
| Slack link cards | `LinkCards.render_card`, `assets/stylesheets/link_cards.css` | Author, channel, timestamp, message body and Slack source link; purple border; no invented journal actions. |
| Due reminders | `Formatter.due_digest_payload`, `due_digest_group_blocks`, `due_digest_line` | Three plain attachment groups; counts and relative day text; links on issue titles, no separate open buttons. |
| App Home | `AppHome.view`, `add_group` | All sections has four tables; one caption each; Subject/Status/Assignee/Due date/Edit issue; project under subject; adjacent selector and Refresh. |
| User mapping | YAML example; `WorkObjects.viewer_for`, `viewer_by_email` | YAML illustration; distinguish incoming email authorization from outgoing name matching. |
| Email preference | `config/locales/en.yml` and personal preference hook | Exact checkbox and help wording; account/security emails unaffected; delivery success is not checked. |
| Administration | `SlackmineAdminController`, `slackmine_admin/index.html.erb`, `_jobs.html.erb`, `AdminOverview`, `JobMonitor` | Two separate tab examples, read-only setting/default/current columns, gray descriptions, bold changes, square color swatches; Sidekiq-only queues/history/test button; no settings editor or task retry/delete controls. |
