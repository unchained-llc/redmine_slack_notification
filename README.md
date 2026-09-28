# Redmine Event Notifications

A Redmine 7 plugin that sends rich event notifications to Slack through the Slack Web API.

The plugin does not use interactive Slack elements such as buttons, menus, or workflow actions. Notifications are rendered as static Slack Block Kit messages.

## Features

- Project-specific Slack channel IDs
- A default Slack channel for projects without a project-specific channel
- Issue, Journal, Wiki, News, Time entry, Version, and Project notifications
- Slack user mentions when an assignee changes
- Slack Markdown blocks for all notification text, including descriptions, comments, changes, and metadata
- Inline PNG/JPEG/GIF images attached to a public Issue comment are shown in Slack
- Sidekiq-based asynchronous delivery
- Private Issues and private comments are not sent to Slack
- Slack API failures do not fail the original Redmine transaction

## Supported events

| Redmine event | Slack label |
|---|---|
| Issue created | 🆕 Issue created |
| Issue updated | 🔄 Issue updated |
| Issue deleted | 🗑️ Issue deleted |
| Comment added | 💬 Comment added |
| Wiki page created | 📚 Wiki page created |
| Wiki page updated | ✏️ Wiki page updated |
| News created or updated | 📰 News updated |
| Time entry created or updated | ⏱️ Time entry updated |
| Version created or updated | 🏷️ Version updated |
| Project updated | 🗂️ Project updated |

When a comment and Issue attributes are changed in the same Journal, one notification contains both the comment and the attribute changes.

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

projects:
  agentic:
    channel_id: 'C0123456789'
  monitoring:
    channel_id: 'C0234567890'

users:
  # Redmine login name or email address: Slack member ID
  alice: 'U0123456789'
  bob: 'U0234567890'
```

`projects` keys must be Redmine project identifiers, not project display names. Channel IDs start with `C` for public channels and commonly `G` for private channels.

Slack configuration selection order:

1. `SLACK_BOT_TOKEN` environment variable
2. `slack.bot_token` in YAML
3. Project-specific `projects.<identifier>.channel_id`
4. `slack.default_channel_id`
5. No notification if the token or channel is missing

The Bot Token requires the `chat:write` scope. To show images from Issue comments, add `files:write` and reinstall the Slack app so the Bot Token gains that scope. The bot must be a member of each target channel.

Comment images are uploaded from the attachments added in the same public Journal, then included in the notification as top-level Slack image blocks at their original Markdown positions. A successful image replaces the source Markdown without an extra attachment link. Images over 20 MB and failed uploads remain clickable Redmine attachment links. Images in private Issues or private comments are never uploaded. Already posted Slack notifications are not changed automatically by installing this version.

All notification text is sent in top-level Slack `markdown` blocks. Redmine Markdown in descriptions and comments is passed through, so repeated `1.` markers render as a numbered list. Metadata and changes are also formatted as Markdown. Slack limits Markdown blocks to 12,000 characters per message; longer notifications are shortened and end with a link to the full Redmine item.

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

Slack API delivery errors are logged and retried by Sidekiq; they do not make the original Redmine operation fail. If Slack has not made a newly uploaded image available to Block Kit yet, the same message is retried briefly before the Job fails.

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
