# Redmine Event Notifications

A Redmine 7 plugin that sends rich event notifications to Slack through the Slack Web API.

The plugin does not use interactive Slack elements such as buttons, menus, or workflow actions. Notifications are rendered as static Slack Block Kit messages.

## Features

- Project-specific Slack channel IDs
- A default Slack channel for projects without a project-specific channel
- Issue, Journal, Wiki, News, Time entry, Version, and Project notifications
- Slack user mentions when an assignee changes
- Markdown-to-Slack-mrkdwn conversion for descriptions, comments, and Wiki edit comments
- Inline PNG/JPEG/GIF images attached to a public Issue comment are shown in Slack
- Sidekiq-based asynchronous delivery
- Private Issues and private comments are not sent to Slack
- Slack API failures do not fail the original Redmine transaction

## Supported events

| YAML path under `events` | Legacy flat key | Redmine event |
|---|---|---|
| `issue.created` | `issue_created` | Issue created |
| `issue.updated.enabled` | `issue_updated` | Parent switch for Issue detail changes |
| `issue.updated.other_changed` | — | Other Issue details, such as category or tracker |
| `issue.deleted` | `issue_deleted` | Issue deleted |
| `issue.comment.added` | `comment_added` | Issue comment added |
| `issue.comment.updated` / `.deleted` | `comment_updated` / `comment_deleted` | Issue comment edited / removed |
| `issue.updated.relation.added` / `.removed` | `relation_added` / `relation_removed` | Issue relation added / removed |
| `issue.updated.status_changed` | `status_changed` | Issue status changed |
| `issue.updated.assignee_changed` | `assignee_changed` | Issue assignee changed |
| `issue.updated.priority_changed` | `priority_changed` | Issue priority changed |
| `issue.updated.due_date_changed` | `due_date_changed` | Issue due date changed |
| `issue.updated.start_date_changed` | `start_date_changed` | Issue start date changed |
| `issue.updated.version_changed` | `version_changed` | Issue target version changed |
| `issue.updated.subject_changed` | `subject_changed` | Issue subject changed |
| `issue.updated.description_changed` | `description_changed` | Issue description changed |
| `issue.updated.custom_field_changed` | `custom_field_changed` | Issue custom field changed |
| `issue.updated.attachment.added` / `.removed` | `attachment_added` / `attachment_removed` | Issue attachment added / removed |
| `issue.updated.parent_changed` | `parent_changed` | Issue parent changed |
| `issue.updated.child.added` / `.removed` | `child_added` / `child_removed` | Child Issue added / removed |
| `wiki.created` / `.updated` / `.deleted` | `wiki_created` / `wiki_updated` / `wiki_deleted` | Wiki page created / updated / deleted |
| `news.created` / `.updated` / `.deleted` | `news_created` / `news_updated` / `news_deleted` | News created / updated / deleted |
| `news.comment.added` / `.updated` | `news_comment_added` / `news_comment_updated` | News comment added / edited |
| `news.comment.deleted` | `news_comment_deleted` | News comment removed |
| `time_entry.created` / `.updated` / `.deleted` | `time_entry_created` / `time_entry_updated` / `time_entry_deleted` | Time entry created / updated / deleted |
| `version.created` / `.updated` / `.deleted` | `version_created` / `version_updated` / `version_deleted` | Version created / updated / deleted |
| `project.updated` | `project_updated` | Project updated |

When a comment, Issue attributes, attachments, and relations change in the same Journal, one notification contains only the enabled parts. If all parts are disabled, no notification is sent. `events.issue.updated.enabled` is the parent switch for every Issue detail path: setting it to `false` suppresses all Issue detail changes even if a child is `true`. With the parent enabled, `other_changed` controls details without a specific key, such as category or tracker. `issue.comment` settings are independent, so a comment can still be sent when Issue details are disabled. `news.comment` settings are likewise independent of `news.updated`. Redmine edits an Issue comment by updating its Journal; clearing the Journal notes produces `issue.comment.deleted`. Standard Redmine News screens do not provide comment editing, but updates to a News Comment record trigger `news.comment.updated`. Deletion notifications do not repeat the removed text. `issue.updated.version_changed` is an Issue target version change; `version.updated` is an edit to a Version record.

Deletion of Wiki pages, News, Time entries, and Versions was not previously notified, so their new deletion keys default to `false`. Set a key to `true` to enable it. Deletion notifications link to the containing project view because the deleted record no longer has a usable page.

Wiki notifications do not include the full Wiki body. They include the Wiki edit comment when one is provided; otherwise, they report that the Wiki content was updated.

When an Issue description, News description, or Wiki body changes, its notification includes a line diff inside the existing colored card. A Markdown `diff` code block marks removed lines with `-` and added lines with `+`, with two unchanged lines of context. The full updated body is not repeated. Long lines and large diffs are shortened with an omission notice; the Issue, News, or Wiki title still links to the full content. Wiki comment-only edits do not produce a body diff.

Edited Issue and News comments use the same line diff format. New comments still show their full text; deletion notifications omit removed text.

## Installation

1. Copy this plugin to the Redmine `plugins` directory:

   ```text
   plugins/redmine_slack_notification
   ```

2. Copy the example configuration file:

   ```bash
   cp plugins/redmine_slack_notification/config/redmine_slack_notification.yml.example \
      config/redmine_slack_notification.yml
   ```

3. Configure the Slack Bot Token and channel IDs.
4. Ensure Sidekiq is running with the `slack` queue.
5. Invite the Slack bot to every target channel.
6. Restart Redmine and Sidekiq.

The plugin does not use project settings tabs or Project custom fields. Channel routing is managed with Slack channel IDs in YAML.

## Configuration

The plugin looks for the configuration file in this order:

1. `config/redmine_slack_notification.yml` under the Redmine application root
2. `plugins/redmine_slack_notification/config/redmine_slack_notification.yml`

Example:

```yaml
slack:
  # Prefer the SLACK_BOT_TOKEN environment variable in production.
  bot_token: 'xoxb-REPLACE-ME'
  default_channel_id: 'C0123456789'
  auto_map_users_by_name: true

events:
  issue:
    created: true
    updated:
      enabled: true
      other_changed: true
      status_changed: true
      relation:
        added: false
        removed: true
    deleted: false
    comment:
      added: false
      updated: true
      deleted: true
  wiki:
    deleted: false

projects:
  agentic:
    channel_id: 'C0123456789'
    events:
      issue:
        comment:
          added: true
  monitoring:
    channel_id: 'C0234567890'

users:
  # Optional explicit mappings; these take precedence over automatic matching.
  # Redmine login name or email address: Slack member ID
  alice: 'U0123456789'
  bob: 'U0234567890'
```

`projects` keys must be Redmine project identifiers, not project display names. Channel IDs start with `C` for public channels and commonly `G` for private channels.

Set a leaf in the table above to `false` to suppress that notification. Missing leaves default to `true`, except `wiki.deleted`, `news.deleted`, `time_entry.deleted`, and `version.deleted`, which default to `false`. `projects.<identifier>.events` overrides the matching global leaf; a project must also enable `issue.updated.enabled` to override a globally disabled Issue update parent. Existing flat event keys remain supported at both levels. At the same level, a nested leaf takes precedence over its flat key. For legacy YAML, `issue_updated` controls both the Issue update parent and other Issue details. Use YAML booleans (`true` or `false`), not quoted strings. Restart Redmine and Sidekiq after editing the configuration; each process caches the YAML.

Slack configuration selection order:

1. `SLACK_BOT_TOKEN` environment variable
2. `slack.bot_token` in YAML
3. Project-specific `projects.<identifier>.channel_id`
4. `slack.default_channel_id`
5. No notification if the token or channel is missing

The Bot Token requires the `chat:write` scope. To show images from Issue comments, add `files:write` and reinstall the Slack app so the Bot Token gains that scope. The bot must be a member of each target channel.

Set `slack.auto_map_users_by_name: true` to mention an assignee automatically when the Redmine login matches exactly one active human Slack member's `profile.display_name` or account `name` (case-insensitive). Explicit `users` mappings take precedence. If the name is missing or ambiguous, the notification displays the Redmine name without a mention. The plugin caches the Slack user directory for 10 minutes and falls back to plain names when the API is unavailable. Automatic name matching requires the Bot Token's `users:read` scope and reinstalling the Slack app after adding that scope. It does not read email addresses and does not require `users:read.email`. The option defaults to `false` for existing installations.

Comment images are uploaded from the attachments added in the same public Journal, then included in the colored notification card at their original Markdown positions. A successful image replaces the source Markdown without an extra attachment link. Slack initially needs a top-level image accessory to share each newly uploaded private file with the channel; the plugin removes those small temporary previews with `chat.update` after posting. If that update fails, the complete colored card remains visible and an error is logged rather than posting a duplicate notification. Images over 20 MB and failed uploads remain clickable Redmine attachment links. Images in private Issues or private comments are never uploaded. Already posted Slack notifications are not changed automatically by installing this version.

Redmine text containing an ordered Markdown list is sent in a Slack `markdown` block inside the colored attachment card. Slack renders repeated `1.` markers as a numbered list, as Redmine does. The card header, dividers, metadata fields, and purple border keep their existing layout even when a comment includes images. Slack limits Markdown blocks to 12,000 characters per message, so longer text uses the existing `mrkdwn` section format.

The configuration file contains credentials and must not be committed to Git. The example file is safe to commit; replace all placeholder values before use.

## Sidekiq

Notifications are enqueued after the Redmine event and delivered by `RedmineSlackNotificationJob` on the `slack` queue.

Example Sidekiq configuration:

```yaml
production:
  :concurrency: 10
:queues:
  - default
  - mailers
  - slack
```

Slack API delivery errors are logged and retried by Sidekiq; they do not make the original Redmine operation fail. If Slack has not processed a newly uploaded image yet, the initial post is retried briefly before the Job fails. A failure to remove temporary image previews after a successful post is logged without retrying the Job, to avoid sending a duplicate notification.

### Running without Sidekiq

Sidekiq is recommended for production, but it is not required. Redmine can run ActiveJob inline by setting the adapter in the appropriate environment configuration:

```ruby
config.active_job.queue_adapter = :inline
```

With the inline adapter, notifications are sent during the original Redmine request instead of being processed by a background worker. This is convenient for development or small installations, but a slow Slack API response can increase request time. For production workloads, use Sidekiq with the `slack` queue.

## Mentions

Map a Redmine login name or email address to a Slack member ID:

```yaml
users:
  alice: 'U0123456789'
```

When the assignee changes, the new assignee is mentioned using Slack's member mention format:

```text
<@U0123456789>
```

The Issue author, Journal author, and Wiki updater are displayed as names and are not automatically mentioned.

## Security and privacy

- Do not commit `redmine_slack_notification.yml`.
- Rotate the Bot Token immediately if it has been exposed.
- Private Issues are excluded.
- Private Journal notes are excluded.
- Bot Tokens and channel IDs are not included in notification messages.
