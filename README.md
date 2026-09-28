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

| YAML event key | Redmine event | Slack label |
|---|---|---|
| `issue_created` | Issue created | 🆕 Issue created |
| `issue_updated` | Other Issue details updated (for example category or tracker) | 🔄 Issue updated |
| `issue_deleted` | Issue deleted | 🗑️ Issue deleted |
| `comment_added` | Issue comment added | 💬 Comment added |
| `relation_added` | Issue relation added | 🔄 Issue updated |
| `relation_removed` | Issue relation removed | 🔄 Issue updated |
| `status_changed` | Issue status changed | 🔄 Issue updated |
| `assignee_changed` | Issue assignee changed | 🔄 Issue updated |
| `priority_changed` | Issue priority changed | 🔄 Issue updated |
| `due_date_changed` | Issue due date changed | 🔄 Issue updated |
| `start_date_changed` | Issue start date changed | 🔄 Issue updated |
| `version_changed` | Issue target version changed | 🔄 Issue updated |
| `subject_changed` | Issue subject changed | 🔄 Issue updated |
| `description_changed` | Issue description changed | 🔄 Issue updated |
| `custom_field_changed` | Issue custom field changed | 🔄 Issue updated |
| `attachment_added` / `attachment_removed` | Issue attachment added / removed | 🔄 Issue updated |
| `parent_changed` | Issue parent changed | 🔄 Issue updated |
| `child_added` / `child_removed` | Child Issue added / removed | 🔄 Issue updated |
| `wiki_created` | Wiki page created | 📚 Wiki page created |
| `wiki_updated` | Wiki page updated | ✏️ Wiki page updated |
| `wiki_deleted` | Wiki page deleted | 🗑️ Wiki page deleted |
| `news_created` | News created | 📰 News updated |
| `news_updated` | News updated | 📰 News updated |
| `news_deleted` | News deleted | 🗑️ News deleted |
| `news_comment_added` | News comment added | 📰 News updated |
| `time_entry_created` | Time entry created | ⏱️ Time entry updated |
| `time_entry_updated` | Time entry updated | ⏱️ Time entry updated |
| `time_entry_deleted` | Time entry deleted | 🗑️ Time entry deleted |
| `version_created` | Version created | 🏷️ Version updated |
| `version_updated` | Version updated | 🏷️ Version updated |
| `version_deleted` | Version deleted | 🗑️ Version deleted |
| `project_updated` | Project updated | 🗂️ Project updated |

When a comment, Issue attributes, attachments, and relations change in the same Journal, one notification contains only the enabled parts. If all parts are disabled, no notification is sent. Issue detail keys (from `relation_added` through `child_removed`) inherit `issue_updated` when omitted, preserving existing configurations. An explicit detail key overrides that inherited setting. `issue_updated` still controls other Issue details, such as category and tracker changes. `version_changed` is the Issue target version; `version_updated` is an edit to a Version record.

Deletion of Wiki pages, News, Time entries, and Versions was not previously notified, so their new deletion keys default to `false`. Set a key to `true` to enable it. Deletion notifications link to the containing project view because the deleted record no longer has a usable page.

Wiki notifications do not include the full Wiki body. They include the Wiki edit comment when one is provided; otherwise, they report that the Wiki content was updated.

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

events:
  issue_created: true
  issue_updated: true
  issue_deleted: false
  comment_added: false
  relation_added: false
  relation_removed: true

projects:
  agentic:
    channel_id: 'C0123456789'
    events:
      comment_added: true
  monitoring:
    channel_id: 'C0234567890'

users:
  # Redmine login name or email address: Slack member ID
  alice: 'U0123456789'
  bob: 'U0234567890'
```

`projects` keys must be Redmine project identifiers, not project display names. Channel IDs start with `C` for public channels and commonly `G` for private channels.

Set any event key in the table above to `false` to suppress that notification. Missing keys default to `true`, except Issue detail keys that inherit `issue_updated` and the new deletion keys that default to `false`. `projects.<identifier>.events` overrides the global `events` value for that project; a project-specific `issue_updated` also takes precedence over global detail keys unless that project sets the detail key explicitly. Use YAML booleans (`true` or `false`), not quoted strings. Restart Redmine and Sidekiq after editing the configuration; each process caches the YAML.

Slack configuration selection order:

1. `SLACK_BOT_TOKEN` environment variable
2. `slack.bot_token` in YAML
3. Project-specific `projects.<identifier>.channel_id`
4. `slack.default_channel_id`
5. No notification if the token or channel is missing

The Bot Token requires the `chat:write` scope. To show images from Issue comments, add `files:write` and reinstall the Slack app so the Bot Token gains that scope. The bot must be a member of each target channel.

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
