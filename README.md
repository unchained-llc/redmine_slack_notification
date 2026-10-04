[English](README.md) | [日本語](README.ja.md)

# Redmine Event Notifications for Slack

A Redmine 7 plugin that sends Issue, Wiki, News, time entry, Version, and Project events to Slack. It can also send daily Issue due-date reminders to assignees by Slack DM. Notifications use a colored Block Kit attachment with a link to the Redmine record. Delivery runs through ActiveJob, normally on Sidekiq's `slack` queue.

The plugin provides notifications only. It does not add Slack buttons, slash commands, project settings tabs, or Redmine custom fields.

## Requirements and setup

- Redmine 7.0 or later.
- A Slack app with a Bot Token and the [`chat:write`](https://docs.slack.dev/reference/methods/chat.postMessage/) scope. Add [`im:write`](https://docs.slack.dev/reference/methods/conversations.open/) for due-date DMs, [`files:write`](https://docs.slack.dev/reference/methods/files.getUploadURLExternal/) for inline Issue images, and [`users:read`](https://docs.slack.dev/reference/methods/users.list/) if you enable automatic user mapping by name. Reinstall the Slack app after changing scopes so its Bot Token receives them.
- A Slack channel for each project, or a default channel. Invite the bot to each destination channel, including private channels.
- For due-date DMs, turn on the Slack app's **App Home → Display Messages tab** setting.
- An ActiveJob worker that processes the `slack` queue. Sidekiq is recommended in production.

1. Place this directory at `plugins/redmine_slack_notification` in the Redmine application.
2. Copy the [example configuration](config/redmine_slack_notification.yml.example) to the application's `config/redmine_slack_notification.yml`.
3. Set the Bot Token and a default or project-specific channel ID. Keep the real YAML file out of Git.
4. Configure Sidekiq to process the `slack` queue and invite the bot to the configured channels.
5. Restart Redmine and Sidekiq. Both processes cache the YAML configuration.

A minimal configuration is:

```yaml
slack:
  # SLACK_BOT_TOKEN can supply the shared token instead.
  bot_token: 'xoxb-REPLACE-ME'
  default_channel_id: 'C0123456789'

projects:
  agentic:
    slack:
      bot_token: 'xoxb-AGENTIC-BOT-TOKEN'
      default_channel_id: 'C0234567890'
```

The plugin reads the first configuration file it finds:

1. `<Redmine root>/config/redmine_slack_notification.yml`
2. `plugins/redmine_slack_notification/config/redmine_slack_notification.yml`

Every top-level configuration group can be overridden under `projects.<identifier>`: `slack`, `events`, `messages`, `users`, and `due_reminders`. Nested maps merge by key, so omitted project keys inherit the global value. Explicit `false` values override `true`. For Bot Tokens, the priority is `projects.<identifier>.slack.bot_token`, then `SLACK_BOT_TOKEN`, then global `slack.bot_token`. For channels, `projects.<identifier>.slack.default_channel_id` takes priority over the older `projects.<identifier>.channel_id`, then a unique automatic name match when enabled, then global `slack.default_channel_id`. Project keys are Redmine **identifiers**, not display names. A missing token or channel prevents delivery and is logged. Channel IDs typically begin with `C` for public channels or `G` for private channels. Keep every project token out of Git and restart Redmine and Sidekiq after changing the YAML.

For example, this project uses its own token and channel, disables comment notifications, hides Issue project metadata, changes the card color and heading, and overrides one Slack user mapping. Other settings retain their global values:

```yaml
projects:
  agentic:
    slack:
      bot_token: 'xoxb-AGENTIC-BOT-TOKEN'
      default_channel_id: 'C0234567890'
      attachment_color: '#123456'
      metadata:
        issue:
          project: false
    events:
      issue:
        comment:
          added: false
    messages:
      events:
        issue:
          created: 'New Agentic issue'
    users:
      alice: 'U0123456789'
```

## Event switches

The `events` tree controls delivery. The table gives every supported leaf and its default when omitted. `true` enables an event and `false` disables it; use YAML booleans, not quoted strings.

| Path below `events` | Default | Trigger |
| --- | :---: | --- |
| `issue.created` | `true` | Issue created |
| `issue.updated.enabled` | `true` | Parent switch for all Issue detail changes below |
| `issue.updated.other_changed` | `true` | Other Issue details, such as tracker |
| `issue.updated.status_changed` | `true` | Status |
| `issue.updated.assignee_changed` | `true` | Assignee |
| `issue.updated.priority_changed` | `true` | Priority |
| `issue.updated.category_changed` | `true` | Category |
| `issue.updated.due_date_changed` | `true` | Due date |
| `issue.updated.start_date_changed` | `true` | Start date |
| `issue.updated.version_changed` | `true` | Issue target version |
| `issue.updated.subject_changed` | `true` | Subject |
| `issue.updated.description_changed` | `true` | Description |
| `issue.updated.custom_field_changed` | `true` | Custom field |
| `issue.updated.attachment.added` / `.removed` | `true` | Attachment added / removed |
| `issue.updated.relation.added` / `.removed` | `true` | Relation added / removed |
| `issue.updated.parent_changed` | `true` | Parent Issue changed |
| `issue.updated.child.added` / `.removed` | `true` | Child Issue added / removed |
| `issue.comment.added` / `.updated` / `.deleted` | `true` | Issue comment added / edited / removed |
| `issue.deleted` | `true` | Issue deleted |
| `wiki.created` / `.updated` | `true` | Wiki page created / updated |
| `wiki.deleted` | `false` | Wiki page deleted |
| `news.created` / `.updated` | `true` | News created / updated |
| `news.deleted` | `false` | News deleted |
| `news.comment.added` / `.updated` / `.deleted` | `true` | News comment added / edited / removed |
| `time_entry.created` / `.updated` | `true` | Time entry created / updated |
| `time_entry.deleted` | `false` | Time entry deleted |
| `version.created` / `.updated` | `true` | Version record created / updated |
| `version.deleted` | `false` | Version record deleted |
| `project.updated` | `true` | Project updated |

`issue.updated.enabled: false` suppresses every Issue detail change, even when an individual detail leaf is `true`. It does **not** suppress `issue.comment.*`, `issue.created`, or `issue.deleted`. `news.comment.*` is independent of `news.updated`. `issue.updated.version_changed` refers to an Issue's target version; `version.updated` refers to editing a Version record.

When one Issue Journal changes several details and adds a comment, the plugin sends one notification containing the enabled parts. Disabled details are omitted. If no part is enabled, it sends nothing. Clearing an existing Issue Journal's notes is reported as `issue.comment.deleted`. Redmine's standard News screen has no comment-edit action, but updating a News Comment record can trigger `news.comment.updated`.

Set global switches under `events`, then override individual leaves for a project under `projects.<identifier>.events`:

```yaml
events:
  issue:
    updated:
      enabled: true
      status_changed: true
      due_date_changed: false
    comment:
      added: false

projects:
  agentic:
    channel_id: 'C0234567890'
    events:
      issue:
        comment:
          added: true
        updated:
          status_changed: false
```

A project override takes precedence over the global value for the same leaf. To override a globally disabled `issue.updated.enabled`, enable that parent for the project as well. Existing flat keys such as `status_changed`, `comment_added`, and `issue_updated` remain supported at either level. At the same level, a nested leaf wins over its flat equivalent. For legacy flat configuration, `issue_updated` controls both the parent switch and `other_changed`. The [example YAML](config/redmine_slack_notification.yml.example) contains the full nested tree.

Deletion of Wiki pages, News, time entries, and Versions defaults to off because those notifications were added after the original events. Deletion links point to a containing project view because the deleted record's own page is gone.

## Notification content

The card contains an event heading, a link to the Redmine record, and relevant text or changed fields. Issue creation and updates include the configured current-value metadata; comment-only and deletion notifications do not. Other event types show their metadata unless disabled below. `slack.attachment_color` changes the card's left border:

```yaml
slack:
  attachment_color: '#2E7D32'
```

The default is `'#6D5DFB'`. Use a quoted six-digit hex value; invalid values fall back to the default. Slack attachments preserve the card border and sections when Markdown lists or images appear.

For Issues, use one `slack.metadata.issue` map for both creation and updates. A field set to `true` appears whenever either notification is sent, even if it did not change. By default, `project`, `updater`, `tracker`, `category`, and `priority` are visible; the other Issue fields are hidden. Unset scalar values show `Not set`; empty lists show `None`. For other notification types, set `slack.metadata.<type>.<field>` to `false` to hide a field; unspecified fields remain visible. Available fields are:

| Type | Fields |
| --- | --- |
| `issue` | `project`, `updater`, `tracker`, `category`, `priority`, `status`, `assignee`, `author`, `target_version`, `start_date`, `due_date`, `estimated_hours`, `done_ratio`, `parent_issue`, `children`, `relations`, `attachments`, `watchers`, `custom_fields` |
| `wiki` | `project`, `updater`, `location` |
| `news`, `news_comment`, `project` | `project`, `updater` |
| `time_entry` | `project`, `updater`, `hours`, `spent_on` |
| `version` | `project`, `updater`, `status`, `due_date` |

For example, this shows the current status and target version on both new Issues and Issue updates, and hides the project on News notifications:

```yaml
slack:
  metadata:
    issue:
      status: true
      target_version: true
    news:
      project: false
```

Set a type such as `wiki: false` or `issue: false` to hide its entire metadata section. `slack.metadata: false` hides metadata everywhere. A section with no visible fields is omitted. `messages.fields` changes labels without changing visibility.

Related Issues and child Issues are linked when available; private Issues are omitted. Custom fields use Redmine's visible custom field values and can be selected by numeric ID:

```yaml
slack:
  metadata:
    issue:
      target_version: true
      relations: true
      custom_fields:
        default: false
        '42': true
```

Issue updates also show a separate **Changes** section with the old and new values of changed fields. Changes to visible fields are always shown. By default, changes to hidden fields are shown too; set `slack.issue_changes_when_hidden: false` to omit them:

```yaml
slack:
  issue_changes_when_hidden: false
```

This switch does not hide the Issue description diff, the subject link, or comments. The `events.issue.updated` switches still decide which changes cause a notification and reach the formatter; this switch only controls whether changes to hidden metadata fields appear in the card. For `custom_fields`, a boolean shows or hides all visible custom fields; a map uses `default` for unspecified IDs. The IDs are Redmine custom field IDs, independent of field names and translated labels.

Existing `metadata.issue.created` / `metadata.issue.updated` maps are still read for compatibility. Replace them with the single `metadata.issue` map when editing your YAML; do not mix the two forms. The former per-field `slack.issue_changes` map and `slack.issue_change_details` switch are no longer used. Use `issue_changes_when_hidden` for hidden-field changes and `events.issue.updated` for notification triggers.

Issue creation includes the description. New comments include their text. An Issue update shows only enabled detail changes and, when applicable, a description diff. A Wiki update shows the edit comment if provided and a body diff when its text changed; Wiki creation does not include the full page body. News creation includes a summary of its description. Deleted comments display removed lines. The record title links to the full content in Redmine.

Redmine Markdown is converted for Slack text. Numbered lists use Slack `markdown` blocks so repeated `1.` markers render as an ordered list; longer content uses `mrkdwn` sections to stay within Slack's 12,000-character Markdown-block budget.

### Ticket Work Object Previews

Set `slack.work_object_previews: true` to add Slack **Task Work Object** metadata to public Issue creation, update, and comment notifications. Omitted or `false` preserves existing notifications. The event body, change diffs, colored attachments, and images remain; Slack can display an additional Work Object card. Deleted Issues, non-Issue notifications, and daily due-date DMs are excluded.

```yaml
slack:
  work_object_previews: true
  metadata:
    issue:
      status: true
      assignee: true
      due_date: true
projects:
  another-project:
    slack:
      work_object_previews: false
```

You can also disable this globally and enable it for individual projects. Restart both Redmine and Sidekiq after changing YAML.

In the Slack app settings, enable **Work Object Previews**, select **Task**, and save. Check workspace preview restrictions too. Notifications use the existing `chat.postMessage` call; notification previews alone do not require new event subscriptions or link-unfurl scopes. See [Slack's notifications implementation](https://docs.slack.dev/messaging/work-objects-implementation/#notifications-implementation).

The header contains the subject, Issue number, and tracker. Standard fields include status, priority, assignee, author, and due date only when enabled by `slack.metadata.issue`. Project, tracker, category, updater, and target version use custom fields with the same visibility settings and `messages.fields` labels. Other fields, descriptions, and comments remain in the existing event card. Assignees and authors use display names without introducing mentions or additional user-directory requests.

The SHA-256 digest of the Issue URL is used as `external_ref.id` to satisfy Slack's ID character restrictions, keeping creation, updates, and comments associated with the same object while distinguishing identical Issue numbers on different Redmine instances. Changing the Redmine hostname changes this identity. The link's `url` remains the original Issue URL.

Notification cards contain a **snapshot from notification generation**. Opening a card or refreshing its detail pane sends `entity_details_requested`; the plugin returns current Issue data through `entity.presentDetails`. See [Slack's details API](https://docs.slack.dev/reference/methods/entity.presentDetails/).

Slack's built-in Work Object refresh uses `link_shared` and `chat.unfurl`. Configure `links:read`, `links:write`, the `link_shared` subscription, and the issue URL host under **App unfurl domains**, then reinstall the app after changing scopes or domains. If Slack returns `cannot_unfurl_url`, check **Workspace settings → Attachments → Blocked previews**: domain blocks prevent both initial unfurls and refreshes even with correct app permissions. See [Slack's refresh event specification](https://docs.slack.dev/reference/events/link_shared/).

To enable details, configure the Slack app and workspace IDs and the **Basic Information → App Credentials → Signing Secret**. This is separate from the Bot Token; `SLACK_SIGNING_SECRET` can supply it instead.

```yaml
slack:
  work_object_previews: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # Replace with the actual Slack member ID
```

1. Deploy the code and YAML, restart Redmine and Sidekiq, and ensure Sidekiq consumes the `slack` queue.
2. Enable **Event Subscriptions** in the Slack app. Set Request URL to `https://redmine.example.com/redmine_slack/events` and confirm **Verified**. Adjust the host and any Redmine installation subdirectory for your deployment.
3. Add `entity_details_requested` under **Subscribe to bot events** and **Save Changes**. No additional OAuth scopes are required for this event or `entity.presentDetails`.
4. Open a Work Object card and check status, assignee, due date, and description. Change the Issue in Redmine and refresh the detail pane to verify the current values. A new notification is unnecessary.

The endpoint verifies the signature, timestamp, app, and workspace before enqueueing work on the existing `slack` queue. Authorization uses explicit `users` mappings from Redmine login/email to Slack ID or enabled `auto_map_users_by_email` matching; `auto_map_users_by_name` is never used to grant access. Unmapped, locked, or unauthorized users, private Issues, inactive projects, and projects with previews disabled receive a restricted response without Issue content. Project-specific apps can override `projects.<identifier>.slack.events` and `users`.

Authorized details include the current title, Issue ID, tracker, project, status, priority, assignee, author, due date, creation/update timestamps, and description (up to 10,000 characters). Detail fields are independent of notification `slack.metadata.issue` settings. Existing comments, Redmine custom fields, and pasted-link unfurls are not included. Editing can be enabled with the setting below.

Failures are logged in Redmine/Sidekiq as `Work Object details failed` or `Work Object unfurl failed`, with the Slack API error code. Successful reads do not produce diagnostic logs. If Slack returns `missing_interactivity_url`, configure the app's **Interactivity & Shortcuts** Request URL.

### Work Object card and detail actions

Set `slack.work_object_actions.enabled: true` to show status, assignee (including unassigned), priority, and due date plus the Edit issue and Assign to me buttons on every public Issue Work Object card with previews enabled. Alternatively, `issue_ids` limits these features to selected issues. Explicit `enabled: false` takes precedence over `issue_ids`. Edit issue opens a Slack modal for permitted status, assignee, priority, due date, and comment changes. The default is disabled. Enable **Interactivity & Shortcuts** in the Slack app and set its Request URL to `https://redmine.example.com/redmine_slack/interactions`. The same `slack.events` signing configuration authenticates the requests.

```yaml
slack:
  work_object_previews: true
  work_object_actions:
    enabled: true
```

For a small pilot, use `issue_ids: [123]` instead of `enabled: true`. Fields and buttons embedded in previously posted cards do not update automatically; those messages need a new notification or an in-place update. The detail pane fetches the current issue whenever it opens.

The detail pane also exposes permitted status, priority, and due date edits and a blank comment input. Assign to me makes no change if the viewer already owns the issue. The modal lists assignable users and an unassigned option when the list has at most 99 users. Every submission rechecks the Slack-to-Redmine user mapping, issue visibility, edit and note permissions, status workflow, active priorities, and assignable users before writing to Redmine. After an edit, the plugin refreshes the originating card or detail pane with the latest issue state. A Slack API failure during card refresh is logged without retrying an already saved Redmine change.

The Work Object's conversation view is separate from Redmine's comment history. Existing Redmine comments are not displayed there. For issues with actions enabled, a new Redmine comment can be added from the detail pane's edit form. Posting comments from notification threads is available through the following setting.

### Match viewers by email

Set `slack.auto_map_users_by_email: true` to authorize Work Object details and Slack thread replies by matching the Slack member's email to exactly one active Redmine user's registered email address (including additional addresses). Matching is case-insensitive. Existing `users` mappings take priority, including mappings that are invalid, locked, ambiguous, or assign the Redmine user to another Slack identity; email matching does not bypass them. Issue visibility and comment permissions are still checked.

```yaml
slack:
  auto_map_users_by_email: true
```

Add both `users:read` and `users:read.email` Bot Token scopes, then reinstall the app. The plugin fetches fresh identity data with `users.info` for each authorization. Missing email, multiple active Redmine matches, inactive users, bots, deleted Slack users, foreign-workspace identities, and API failures deny automatic access. The configured `slack.events.team_id` must match the Slack identity's workspace. Email identity data is not cached or saved in a new table, Redis, or a file, and is not included in diagnostic logs. Override the switch under `projects.<identifier>.slack.auto_map_users_by_email`.

This is distinct from `auto_map_users_by_name`, which only resolves outgoing mentions and due-reminder recipients. Email matching is for incoming viewer/comment authorization and does not automatically enable outgoing mentions or DMs.

### Match projects to channels by name

Enable `slack.auto_map_channels_by_name: true` to match Redmine project **display names** to Slack channel names. Names are trimmed and compared case-insensitively; whitespace becomes a hyphen (`Customer Support` → `customer-support`). Project identifiers are not used for matching. No fuzzy matching, channel creation, or automatic joining is performed.

```yaml
slack:
  auto_map_channels_by_name: true
  default_channel_id: 'C0123456789' # Optional fallback
projects:
  example:
    slack:
      auto_map_channels_by_name: false
      default_channel_id: 'C0234567890'
```

Routing priority is explicit project `slack.default_channel_id`, legacy project `channel_id`, a unique name match, then global `slack.default_channel_id`. A missing match, ambiguous match, or API failure uses the global fallback; without a fallback, delivery is skipped and logged. The switch can be overridden per project.

The plugin uses `users.conversations` to list only channels the Bot belongs to. Add `channels:read` for public channels and `groups:read` for private channels, then reinstall the app. These are separate from the `*:history` scopes used for threaded notifications. Archived channels and DMs are excluded. Listings are cached by Bot Token in process memory for ten minutes; no DB, Redis, file storage, or Rails cache is used. Rename/membership changes can take up to ten minutes to be reflected; restarting workers clears their caches. Listing is bounded to ten pages of 200 channels; incomplete or failed listings are not used for matching. Each worker has its own cache.

Automatic routing also applies to comment notification threads and Slack-to-Redmine thread replies. Projects do not need YAML entries to participate when the global switch is enabled; existing reply permissions and explicit user mappings or enabled email matching still apply.

### Threaded Redmine comment notifications

Set `slack.comment_notifications_in_threads: true` to post comment-only additions, edits, and deletions in the latest matching Issue notification thread in the configured channel. Omitted or `false` keeps channel posts. Updates that also contain enabled Issue changes remain channel posts. When a thread is found, new comments show a configurable heading and the formatted comment body, without repeating the Issue link, full event card, or Work Object preview. Comment edits retain the configured body/diff presentation; deletions retain the removal diff. Images continue to be supported. Channel fallback uses the full notification. This option works independently of `slack.thread_comments` and Work Object Previews.

```yaml
slack:
  comment_notifications_in_threads: true
  events:
    app_id: 'A0123456789'
```

Override per project under `projects.<identifier>.slack.comment_notifications_in_threads`. The Bot must belong to the channel and have `groups:history` for private channels or `channels:history` for public channels; reinstall the app after adding scopes. `slack.events.app_id` identifies this app's notifications. No new Event Subscription is required for outgoing comment notifications.

Customize the compact notification heading with `messages.thread_notifications.added_header`, `updated_header`, and `deleted_header`. Templates support `%{product_name}`, `%{id}`, `%{actor}`, and `%{subject}`, including project-specific overrides under `projects.<identifier>.messages`. Defaults and examples are English. The heading is separate from the comment body, which is displayed only once. References to the current Issue using `#%{id}` in the heading automatically link to its Redmine page.

```yaml
messages:
  thread_notifications:
    added_header: '%{product_name} #%{id}: New comment'
    updated_header: '%{product_name} #%{id}: Comment updated'
    deleted_header: '%{product_name} #%{id}: Comment deleted'
```

Each delivery searches up to three history pages, requesting 100 messages per page (Slack may return fewer). Only root notifications from the configured app with the exact Issue subject link qualify; user messages, links in comment bodies, and broadcast replies do not. Missing matches, missing app configuration, and lookup errors fall back to a normal channel post. No thread mapping is saved in a database, Redis, or a file. The latest notification may differ from the thread where a conversation started; older threads outside the search range are not found. History requests add latency and consume Slack API rate limits. Existing cards are not moved.

### Add Redmine comments from notification threads

Set `slack.thread_comments: true` to save text replies to this plugin's Issue notifications as Redmine comments authored by the replying user. Omitted or `false` disables the feature. Work Object Previews are optional.

```yaml
slack:
  thread_comments: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # Actual Slack member ID
projects:
  another-project:
    slack:
      thread_comments: false
```

For private channels, add the Bot Token scope `groups:history` and subscribe to `message.groups`. Public channels use `channels:history` and `message.channels`. Reinstall the app after adding scopes. Request URL and signature verification are shared with Work Object details. The bot must be a member of the channel. See [Slack's message events](https://docs.slack.dev/reference/events/message/).

No extra tables, DB migrations, or Redis processing-state entries are required. The plugin fetches only the parent notification through `conversations.history`, verifies its app ID and canonical Issue subject URL, and accepts replies only in channels currently configured as notification destinations. Existing notifications are supported. Replies to other apps, users, or arbitrary Issue links are ignored.

Authorization requires an explicit `users` mapping or enabled unique email matching to an active Redmine user, Issue visibility, and tracker-aware permission to add notes. Private Issues, inactive projects, and unmapped users are denied. Incoming Slack text is stored up to 10,000 characters without adding IDs or provenance lines. The existing Journal `created_on` is set to the original Slack posting time, parsed without floating-point conversion. The Issue, mapped author, and posting time identify repeated deliveries. The existing Issue row lock serializes duplicate checks and comment saves. No additional tables, columns, Redis state, or state files are required. Editing the comment text does not affect duplicate detection. Legacy comments containing provenance lines are still recognized as duplicates.

Reliable duplicate detection requires the existing `journals.created_on` column to preserve microseconds (six fractional digits). Lower timestamp precision may treat distinct replies from the same author as duplicates. A different comment by the same mapped author on the same Issue at the exact same timestamp is also treated as a duplicate. Deleting the comment or changing its author or posting time removes its duplicate protection. Existing provenance lines are not removed automatically.

Customize the service name shown in Work Object cards and detail headers/open buttons with `messages.work_objects.product_name` (default: `Redmine`). Thread reply feedback supports `%{id}` and `%{product_name}`. References using `#%{id}` automatically link to the Issue, including success and restriction feedback. All these keys support overrides under `projects.<identifier>.messages`.

```yaml
messages:
  work_objects:
    product_name: 'Example Tracker'
  thread_comments:
    saved: '✅ Comment added to %{product_name} #%{id}.'
    restricted: '⚠️ Could not add the comment. Check your permissions.'
```

These settings affect new notifications and freshly requested details. Existing notification cards are not rewritten. Slack-owned UI text such as “Details” and “Conversations” follows Slack’s language settings.

The result is posted to the same thread. Customize the text with `messages.thread_comments.saved` (supports `%{id}` and `%{product_name}`) and `messages.thread_comments.restricted`. The normal Slack notification for the newly saved comment is suppressed; standard Redmine email notifications and other callbacks still run. Bot messages, Slack edits/deletions, and attached files are not synchronized. Slack mentions and link syntax are not converted to Redmine markup. If result feedback fails after saving, the comment remains saved and the failure is logged. Disabling the feature keeps previously saved comments.

After deploying code and YAML, restart Redmine and Sidekiq. Reply to a test Issue notification and verify the author, exact comment text, and success response. Also check unauthorized users, bot replies, and Slack edits to ensure they do not add comments.

### Body diffs

By default, edits to Issue descriptions and comments, Wiki bodies, and News descriptions and comments show a line diff. The `diff` code block marks removed lines with `-` and added lines with `+`, with two unchanged lines of context. Long lines and large diffs are shortened; follow the record link for the full text. A Wiki edit that changes only its edit comment has no body diff.

Set `slack.body_diff` for each type. `false` shows the updated text instead of a diff:

```yaml
slack:
  body_diff:
    issue:
      description: true
      comment: false
    wiki:
      body: true
    news:
      description: false
      comment: true
```

Missing entries default to `true`. Setting `issue`, `wiki`, or `news` to `false` disables diffs for all children of that parent. The older scalar form, `body_diff: true` or `body_diff: false`, still applies to every type. Deleted Issue and News comments **always** show their removed lines as a diff, regardless of this setting.

### Inline Issue images

For new public Issues and public Issue comments, the plugin recognizes local Markdown image references such as `![](screenshot.png)`. On creation, it can upload a matching image attached to the Issue; for comments, it uses images attached to the same Journal. Supported formats are PNG, JPEG, and GIF. Images appear inside the colored card. It does not fetch remote URLs or filesystem paths. Images must be nonempty and at most 20 MiB. The Bot Token needs `files:write`.

This also applies when an existing public Issue comment is edited. With `body_diff.issue.comment: false`, an eligible image appears at its Markdown position in the updated text. With `true`, image previews appear after the comment diff. Deleted comments do not re-upload images. A successful upload replaces the Markdown reference without adding a duplicate attachment link. If a recognized image cannot be uploaded, including when it exceeds the size limit, the notification contains a link to its Redmine attachment or Issue.

To share a newly uploaded private file with the channel, the plugin posts a temporary top-level reference along with the complete colored card, then removes the temporary preview with `chat.update`. If cleanup fails, it logs the error without reposting the notification. A newly uploaded file that is not ready yet is retried briefly. Already posted Slack messages are not rewritten when this plugin is updated.

### Wording and templates

The top-level `messages` tree changes notification wording; it does not control whether an event is sent. All keys are optional. Omitted or empty strings use built-in defaults. The [example YAML](config/redmine_slack_notification.yml.example) lists every available key with sample values:

| Group | Controls |
| --- | --- |
| `messages.events` | Visible event labels such as `Issue updated` |
| `messages.icons` | Event emoji |
| `messages.sections` | Card section headings |
| `messages.fields` | Metadata and changed-field labels |
| `messages.relations` | Relation names |
| `messages.values` | Placeholder words and changed-value verbs |
| `messages.diff` | Diff heading and truncation notice |
| `messages.images` | Temporary preview wording, alt text, and fallback link label |
| `messages.templates` | Visible Issue-update heading and plain-text attachment fallbacks |
| `messages.due_reminders` | Daily DM headings, labels, relative timing, and fallbacks |

An Issue update heading uses the Redmine user who made the update. Its default format is `🔄 Alice *Issue updated*` in Slack markup. You can change the text after the icon without editing the plugin:

```yaml
messages:
  templates:
    issue_updated_header: '%{actor} *%{event}*'
```

The `issue_updated_header` template also applies when an Issue update contains a comment. Issue creation, deletion, and standalone comment headings retain their own event labels. The actor is shown as a name, not as a Slack mention.

The other templates produce plain-text attachment fallbacks for clients that cannot display the rich card:

| Template | Applies to | Available placeholders |
| --- | --- | --- |
| `issue_updated_header` | Visible Issue-update heading | `%{actor}`, `%{event}` |
| `issue_fallback` | Issue creation, update without a comment, and deletion | `%{project}`, `%{actor}`, `%{action}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `journal_fallback` | Issue changes with a comment and standalone Issue comments | `%{project}`, `%{actor}`, `%{event}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `generic_fallback` | Wiki, News, News comments, time entries, Versions, and Projects | `%{event}`, `%{subject}` |

For example, `generic_fallback: '%{event}: %{subject}'` produces `News updated: Example title`. Keep placeholders in `%{name}` form. An unknown placeholder causes that template to fall back to its built-in default.

### Assignee mentions

When an Issue assignee changes, an explicit `users` mapping can turn the new assignee into a Slack mention:

```yaml
users:
  # Redmine login or email address: Slack member ID
  alice: 'U0123456789'
```

With `slack.auto_map_users_by_name: true`, the plugin can also match a Redmine **login** to exactly one active human Slack member's `profile.display_name` or account `name`, case-insensitively. Explicit mappings win. Missing or ambiguous matches stay as plain Redmine names. The directory is cached for ten minutes; an API failure also falls back to plain names. Automatic mapping requires `users:read` and an app reinstall after the scope is added. It does not read email addresses and does not require `users:read.email`.

The new assignee uses Slack's `<@U0123456789>` mention format. Issue authors, Journal authors, Wiki updaters, and the actor in the Issue-update heading are displayed as names without automatic mentions.

## Daily due-date DMs

Run the task once a day in the Redmine application's time zone. It queues jobs on the `slack` queue; the worker sends the DMs:

```bash
cd /path/to/redmine
bundle exec rake redmine:slack:due_reminders RAILS_ENV=production
```

Schedule the task once a day with the scheduler used by your Redmine installation. Each execution sends another digest, even on the same day.

For cron, put the command in a small script that changes to the Redmine directory first:

```sh
#!/bin/sh
cd /path/to/redmine || exit 1
bundle exec rake redmine:slack:due_reminders days=7 RAILS_ENV=production
```

The task accepts the same filters as Redmine's reminder command. Set them as Rake environment arguments; omitted filters include all matching Issues:

| Option | Meaning |
| --- | --- |
| `days` | Days before the due date. Overrides `due_reminders.days` in the YAML, including project overrides. Without it, the YAML setting applies (default: 3). |
| `tracker` | Tracker ID. |
| `project` | Project ID or identifier. |
| `users` | Comma-separated Redmine user IDs whose assigned Issues should be included. |
| `version` | Target version name, matched case-insensitively as in Redmine. |

For example, to restrict a run to users 3 and 5, or to combine all filters:

```bash
bundle exec rake redmine:slack:due_reminders users=3,5 RAILS_ENV=production
bundle exec rake redmine:slack:due_reminders days=7 tracker=2 project=example users=3,5 version="1.0" RAILS_ENV=production
```

Only Issues matching every supplied filter are included, and the worker checks the filters and assignee again before sending. Invalid values or nonexistent users, trackers, projects, and versions stop the task before any jobs are queued. Every invocation sends the current matching Issues again, including Issues already sent earlier that day.

By default, assigned open Issues are included daily from **three days before their due date** through every overdue day, until their status is marked **closed** in Redmine. The worker sends one compact DM per assignee and groups the linked Issues under overdue, due today, and upcoming headings. Each group has its own color: overdue is red, due today is amber, and upcoming uses the configured attachment color. Issue lines show relative timing without repeating the calendar date; the due-today heading carries that context. A digest with more than 100 Issues is split into numbered messages. Separate bot tokens or Slack user mappings can produce a separate digest for each app. Each run sends the current matching Issues, even if the task already ran that day.

```yaml
due_reminders:
  enabled: true
  days: 3
  colors:
    overdue: '#D92D20'
    today: '#F79009'
    # upcoming: '#6D5DFB'
projects:
  example:
    due_reminders:
      enabled: false
```

Set `due_reminders.colors.overdue`, `.today`, and `.upcoming` to six-digit hex colors. Invalid or omitted values use the defaults; an omitted upcoming color uses `slack.attachment_color`. Colors can also be overridden per project under `projects.<identifier>.due_reminders.colors`.

The assignee must be an active Redmine user who can view the Issue, and must map to a Slack user through `users` or `slack.auto_map_users_by_name`. Group assignees and unmapped users are skipped and logged. Private Issues can be sent to their own assignee by DM when Redmine grants that user access. DM delivery needs a Bot Token with `chat:write` and `im:write`; it does not use the project's channel ID. In the Slack app settings, enable **App Home → Messages Tab → Display Messages tab**; otherwise Slack returns `messages_tab_disabled` even after `conversations.open` succeeds. After adding scopes, reinstall the Slack app. Verify a test Issue in the recipient's Slack DM before relying on the schedule.

The digest wording is configurable under `messages.due_reminders` in the YAML file. The [example configuration](config/redmine_slack_notification.yml.example) lists every key and its placeholders. For example, change the title and the overdue group label without changing the other groups:

```yaml
messages:
  due_reminders:
    title: '📋 *Due reminders: %{count}%{suffix}*'
    overdue_label: '🚨 Overdue'
```

The same keys can be overridden under `projects.<identifier>.messages.due_reminders`.

## Delivery and operations

`RedmineSlackNotificationJob` is enqueued after the Redmine event on the `slack` ActiveJob queue. For Sidekiq, include that queue in its configuration, for example:

```yaml
:queues:
  - default
  - mailers
  - slack
```

Slack API failures are logged and retried by Sidekiq. They do not roll back the Redmine operation. A failure to remove temporary image previews after a successful post is logged but does not retry the job, avoiding a duplicate message. Check the `RedmineSlackNotificationJob` and `RedmineSlackNotification` log lines when a notification is absent.

For development, ActiveJob's inline adapter can run without Sidekiq:

```ruby
config.active_job.queue_adapter = :inline
```

Inline delivery happens during the Redmine request and may increase response time if Slack is slow. Use a worker that processes the `slack` queue in production.

If a notification is missing, check in this order:

1. The relevant event leaf and any parent switch are enabled globally and for the project.
2. The running Redmine and Sidekiq processes have the intended token. `SLACK_BOT_TOKEN` overrides YAML.
3. The project identifier maps to the intended channel, or a default channel is configured, and the bot is a member.
4. The Bot Token has `chat:write`, plus `files:write` or `users:read` for those optional features. Reinstall after adding a scope.
5. Sidekiq processes the `slack` queue; inspect the job error and Slack API error code in the log.

A YAML change requires restarting both Redmine and Sidekiq. A successful job post confirms API delivery; check the target channel to confirm the visible layout and images. Existing messages are not updated retroactively.

## Privacy and development

Channel notifications exclude private Issues and private Journal notes. Daily DMs may include private Issues only when the assignee can view them in Redmine. Images from private Issues or notes are not uploaded. Do not commit a real `redmine_slack_notification.yml` or expose the Bot Token in logs, examples, or support requests. Rotate a token if it is exposed.

The repository's local test suite can be run with:

```bash
ruby -Itest test/image_notification_test.rb
ruby -Itest test/slack_events_controller_test.rb
```

These tests exercise notification formatting and delivery logic with stubs. Additionally, run `ruby -Itest test/thread_comments_persistence_test.rb` where ActiveRecord and sqlite3 are available to check persistence, duplicate suppression, permission denial, and notification-loop suppression using in-memory Issue/Journal fixture tables. These tests do not connect to production databases or Redis, post to Slack, or verify a live Redmine installation.
