[English](README.md) | [日本語](README.ja.md)

# Redmine の Slack 通知

Redmine 7 の Issue、Wiki、News、作業時間、Version、Project のイベントを Slack に通知するプラグインです。Issue の期日が近づいたとき、担当者に Slack DM で毎日リマインダーを送ることもできます。通知には Redmine の対象ページへのリンクと、色付きの Block Kit attachment を使います。配信は ActiveJob を経由し、通常は Sidekiq の `slack` キューで処理します。

このプラグインは通知専用です。Slack ボタン、スラッシュコマンド、プロジェクト設定タブ、Redmine のカスタムフィールドは追加しません。

## 要件とセットアップ

- Redmine 7.0 以降。
- Bot Token と [`chat:write`](https://docs.slack.dev/reference/methods/chat.postMessage/) スコープを持つ Slack アプリ。期日リマインダーの DM には [`im:write`](https://docs.slack.dev/reference/methods/conversations.open/)、Issue の画像を本文内に表示するには [`files:write`](https://docs.slack.dev/reference/methods/files.getUploadURLExternal/)、名前によるユーザーの自動対応付けには [`users:read`](https://docs.slack.dev/reference/methods/users.list/) も必要です。スコープを変更したら、Slack アプリを再インストールして Bot Token に反映してください。
- プロジェクトごとの通知先チャンネル、またはデフォルトのチャンネル。非公開チャンネルを含め、通知先にはボットを招待してください。
- 期日リマインダーの DM を使う場合は、Slack アプリの **App Home → Display Messages tab** を有効にしてください。
- `slack` キューを処理する ActiveJob ワーカー。本番環境では Sidekiq を推奨します。

1. このディレクトリを Redmine の `plugins/redmine_slack_notification` に配置します。
2. [設定例](config/redmine_slack_notification.yml.example)を Redmine アプリケーションの `config/redmine_slack_notification.yml` にコピーします。
3. Bot Token と、デフォルトまたはプロジェクト固有のチャンネル ID を設定します。実際の YAML ファイルは Git に含めないでください。
4. Sidekiq が `slack` キューを処理するように設定し、ボットを通知先チャンネルに招待します。
5. Redmine と Sidekiq を再起動します。どちらのプロセスも YAML 設定をキャッシュします。

最小限の設定例:

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

プラグインは、次の順で最初に見つかった設定ファイルを読み込みます。

1. `<Redmine root>/config/redmine_slack_notification.yml`
2. `plugins/redmine_slack_notification/config/redmine_slack_notification.yml`

最上位の設定グループ `slack`、`events`、`messages`、`users`、`due_reminders` は、`projects.<identifier>` 以下で上書きできます。ネストしたマップはキーごとにマージされ、省略したプロジェクト設定は全体設定を引き継ぎます。`false` を明示すると、全体設定の `true` を上書きします。Bot Token の優先順位は、`projects.<identifier>.slack.bot_token`、`SLACK_BOT_TOKEN`、全体の `slack.bot_token` の順です。チャンネルは、`projects.<identifier>.slack.default_channel_id`、従来の `projects.<identifier>.channel_id`、全体の `slack.default_channel_id` の順です。プロジェクトのキーには表示名ではなく Redmine の**識別子**を使います。Token またはチャンネルがない場合、通知は送られずログに記録されます。チャンネル ID は通常、公開チャンネルが `C`、非公開チャンネルが `G` で始まります。プロジェクト固有の Token も Git に含めず、YAML の変更後は Redmine と Sidekiq を再起動してください。

次の例では、プロジェクト固有の Token とチャンネルを使い、コメント通知と Issue のプロジェクト情報を非表示にし、カードの色・見出し・Slack ユーザーの対応付けを変更します。その他の設定は全体設定を引き継ぎます。

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

## イベントの切り替え

通知するイベントは `events` ツリーで制御します。次の表は、各キーと、省略した場合の初期値を示します。`true` で有効、`false` で無効です。引用符で囲んだ文字列ではなく、YAML の真偽値を使ってください。

| `events` 以下のパス | 初期値 | 対象 |
| --- | :---: | --- |
| `issue.created` | `true` | Issue の作成 |
| `issue.updated.enabled` | `true` | 以下の Issue 詳細変更に対する親スイッチ |
| `issue.updated.other_changed` | `true` | Tracker など、その他の Issue 詳細 |
| `issue.updated.status_changed` | `true` | ステータス |
| `issue.updated.assignee_changed` | `true` | 担当者 |
| `issue.updated.priority_changed` | `true` | 優先度 |
| `issue.updated.category_changed` | `true` | カテゴリ |
| `issue.updated.due_date_changed` | `true` | 期日 |
| `issue.updated.start_date_changed` | `true` | 開始日 |
| `issue.updated.version_changed` | `true` | 対象バージョン |
| `issue.updated.subject_changed` | `true` | 件名 |
| `issue.updated.description_changed` | `true` | 説明 |
| `issue.updated.custom_field_changed` | `true` | カスタムフィールド |
| `issue.updated.attachment.added` / `.removed` | `true` | 添付ファイルの追加・削除 |
| `issue.updated.relation.added` / `.removed` | `true` | 関連の追加・削除 |
| `issue.updated.parent_changed` | `true` | 親 Issue |
| `issue.updated.child.added` / `.removed` | `true` | 子 Issue の追加・削除 |
| `issue.comment.added` / `.updated` / `.deleted` | `true` | Issue コメントの追加・編集・削除 |
| `issue.deleted` | `true` | Issue の削除 |
| `wiki.created` / `.updated` | `true` | Wiki ページの作成・更新 |
| `wiki.deleted` | `false` | Wiki ページの削除 |
| `news.created` / `.updated` | `true` | News の作成・更新 |
| `news.deleted` | `false` | News の削除 |
| `news.comment.added` / `.updated` / `.deleted` | `true` | News コメントの追加・編集・削除 |
| `time_entry.created` / `.updated` | `true` | 作業時間の作成・更新 |
| `time_entry.deleted` | `false` | 作業時間の削除 |
| `version.created` / `.updated` | `true` | Version レコードの作成・更新 |
| `version.deleted` | `false` | Version レコードの削除 |
| `project.updated` | `true` | Project の更新 |

`issue.updated.enabled: false` は、個別の詳細設定が `true` でも、Issue の詳細変更通知をすべて抑止します。`issue.comment.*`、`issue.created`、`issue.deleted` は抑止しません。`news.comment.*` は `news.updated` から独立しています。`issue.updated.version_changed` は Issue の対象バージョンの変更、`version.updated` は Version レコード自体の編集を指します。

1 つの Issue Journal で複数の詳細を変更し、コメントも追加した場合は、有効な部分をまとめて 1 件の通知を送ります。無効な詳細は含めません。有効な部分がなければ送信しません。既存の Issue Journal のコメントを空にすると、`issue.comment.deleted` として通知します。Redmine 標準の News 画面ではコメントを編集できませんが、News Comment レコードを更新すると `news.comment.updated` を通知できます。

全体の切り替えは `events` 以下に置き、プロジェクト固有の設定は `projects.<identifier>.events` 以下で上書きします。

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

同じキーでは、プロジェクト固有の値が全体の値より優先されます。全体で無効にした `issue.updated.enabled` をプロジェクトで上書きする場合は、親スイッチもそのプロジェクトで有効にしてください。従来のフラットなキー `status_changed`、`comment_added`、`issue_updated` なども両方の階層で使えます。同じ階層では、ネストしたキーが対応するフラットなキーより優先されます。従来のフラット設定では、`issue_updated` が親スイッチと `other_changed` の両方を制御します。[設定例](config/redmine_slack_notification.yml.example)にネストした設定の全体を掲載しています。

Wiki ページ、News、作業時間、Version の削除通知は、後から追加されたため初期状態では無効です。削除されたレコードのページは存在しないため、削除通知のリンクは所属するプロジェクトのページを指します。

## 通知内容

カードにはイベントの見出し、Redmine の対象レコードへのリンク、関連する本文や変更項目を表示します。Issue の作成・更新通知には設定した現在値のメタデータを含めますが、コメントのみの通知と削除通知には含めません。その他のイベントでは、以下の設定で無効にしない限りメタデータを表示します。`slack.attachment_color` はカードの左側の線の色を変更します。

```yaml
slack:
  attachment_color: '#2E7D32'
```

初期値は `'#6D5DFB'` です。6 桁の 16 進カラーコードを引用符で囲んで指定してください。無効な値は初期値に戻ります。Markdown のリストや画像があっても、Slack の attachment はカードの左線とセクションを維持します。

Issue には、作成・更新の両方に共通する `slack.metadata.issue` マップを 1 つ使います。項目を `true` にすると、変更の有無にかかわらず、どちらの通知でも表示します。初期状態では `project`、`updater`、`tracker`、`category`、`priority` を表示し、その他の Issue 項目は非表示です。未設定の単一値は `Not set`、空のリストは `None` と表示します。その他の通知種別では、`slack.metadata.<type>.<field>` を `false` にすると項目を非表示にでき、省略した項目は表示されます。指定できる項目は次のとおりです。

| 種別 | 項目 |
| --- | --- |
| `issue` | `project`, `updater`, `tracker`, `category`, `priority`, `status`, `assignee`, `author`, `target_version`, `start_date`, `due_date`, `estimated_hours`, `done_ratio`, `parent_issue`, `children`, `relations`, `attachments`, `watchers`, `custom_fields` |
| `wiki` | `project`, `updater`, `location` |
| `news`, `news_comment`, `project` | `project`, `updater` |
| `time_entry` | `project`, `updater`, `hours`, `spent_on` |
| `version` | `project`, `updater`, `status`, `due_date` |

次の例は、Issue の作成・更新通知で現在のステータスと対象バージョンを表示し、News 通知ではプロジェクトを非表示にします。

```yaml
slack:
  metadata:
    issue:
      status: true
      target_version: true
    news:
      project: false
```

`wiki: false` や `issue: false` のように種別を指定すると、その種別のメタデータセクション全体を非表示にできます。`slack.metadata: false` はすべてのメタデータを非表示にします。表示項目がないセクションは省略します。`messages.fields` は表示・非表示を変えずにラベルだけを変更します。

関連 Issue と子 Issue は、参照できる場合にリンクにします。非公開 Issue は省略します。カスタムフィールドには Redmine 上で閲覧できる値を使い、数値 ID で表示対象を選べます。

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

Issue の更新通知では、変更前後の値を示す独立した **Changes** セクションも表示します。表示対象の項目の変更は常に表示します。初期状態では非表示項目の変更も表示しますが、`slack.issue_changes_when_hidden: false` で省略できます。

```yaml
slack:
  issue_changes_when_hidden: false
```

この設定は Issue の説明文の差分、件名のリンク、コメントを非表示にしません。`events.issue.updated` の各スイッチは、どの変更が通知を発生させて formatter に渡されるかを決めます。この設定は、メタデータで非表示にした項目の変更をカードに表示するかだけを制御します。`custom_fields` は真偽値で閲覧可能な全カスタムフィールドを表示・非表示にでき、マップを使う場合は `default` が指定されていない ID に適用されます。ID は Redmine のカスタムフィールド ID で、項目名や翻訳済みラベルとは無関係です。

互換性のため、従来の `metadata.issue.created` / `metadata.issue.updated` マップも読み込みます。YAML を編集する際は、単一の `metadata.issue` マップへ置き換え、両方の形式を混在させないでください。以前の項目別 `slack.issue_changes` マップと `slack.issue_change_details` スイッチは使われません。非表示項目の変更には `issue_changes_when_hidden`、通知を発生させる変更には `events.issue.updated` を使ってください。

Issue の作成通知には説明文、新しいコメントの通知にはコメント本文を含めます。Issue の更新通知には、有効な詳細変更と、該当する場合は説明文の差分だけを表示します。Wiki の更新では、編集コメントがあればそれを表示し、本文が変更された場合は差分も表示します。Wiki 作成時には本文全体を含めません。News の作成通知には説明文の要約を含めます。削除されたコメントでは削除行を表示します。レコードのタイトルから Redmine の全文へ移動できます。

Redmine の Markdown は Slack 用テキストに変換します。番号付きリストには Slack の `markdown` ブロックを使い、繰り返し現れる `1.` が順序付きリストとして表示されるようにします。長い内容には `mrkdwn` セクションを使い、Slack の Markdown ブロックの 12,000 文字制限に収めます。

### 本文の差分

初期状態では、Issue の説明文・コメント、Wiki の本文、News の説明文・コメントを編集すると行単位の差分を表示します。`diff` コードブロックでは、削除行に `-`、追加行に `+` を付け、前後に変更のない行を 2 行ずつ含めます。長い行や大きな差分は短縮されるため、全文はレコードのリンクから確認してください。編集コメントだけを変更した Wiki 更新には本文差分を表示しません。

種別ごとに `slack.body_diff` を設定します。`false` にすると差分の代わりに更新後の本文を表示します。

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

省略した項目の初期値は `true` です。`issue`、`wiki`、`news` 自体を `false` にすると、その下のすべての差分を無効にします。従来の単一値 `body_diff: true` / `body_diff: false` も、すべての種別に適用されます。削除された Issue・News コメントは、この設定にかかわらず削除行を**常に**差分で表示します。

### Issue の画像表示

公開 Issue の作成・コメント通知では、`![](screenshot.png)` のようなローカル Markdown 画像参照を認識します。作成時は Issue に添付された同名の画像を、コメントでは同じ Journal に添付された画像をアップロードできます。対応形式は PNG、JPEG、GIF です。画像は色付きカードの中に表示されます。外部 URL やファイルシステム上のパスは取得しません。画像は空でないことと、20 MiB 以下であることが必要です。Bot Token には `files:write` が必要です。

公開 Issue の既存コメントを編集した場合にも適用されます。`body_diff.issue.comment: false` では、対象の画像を更新後の本文の Markdown 上の位置に表示します。`true` では、コメントの差分の後に画像プレビューを表示します。削除されたコメントの画像は再アップロードしません。アップロードに成功すると、Markdown の画像参照を置き換え、重複した添付リンクは追加しません。画像がサイズ上限を超えるなどしてアップロードできない場合は、Redmine の添付ファイルまたは Issue へのリンクを通知に含めます。

新しくアップロードした非公開ファイルをチャンネルに共有するため、プラグインはカード全体とともに一時的な最上位の参照を投稿し、その後 `chat.update` で一時プレビューを削除します。削除に失敗した場合は、通知を再投稿せずエラーを記録します。アップロード直後に利用可能になっていないファイルは、短時間リトライします。プラグイン更新前に投稿された Slack メッセージは書き換えません。

### 文言とテンプレート

最上位の `messages` ツリーで通知文言を変更できます。イベントを送るかどうかは制御しません。すべてのキーは任意です。省略した値や空文字列には組み込みの初期値を使います。[設定例](config/redmine_slack_notification.yml.example)には、使用できるすべてのキーとサンプル値を掲載しています。

| グループ | 設定対象 |
| --- | --- |
| `messages.events` | `Issue updated` などのイベント名 |
| `messages.icons` | イベントの絵文字 |
| `messages.sections` | カードのセクション見出し |
| `messages.fields` | メタデータと変更項目のラベル |
| `messages.relations` | 関連の名称 |
| `messages.values` | 代替表示の語句と変更を示す動詞 |
| `messages.diff` | 差分の見出しと省略通知 |
| `messages.images` | 一時プレビューの文言、代替テキスト、リンクのラベル |
| `messages.templates` | Issue 更新時の見出しと、attachment のプレーンテキスト代替表示 |
| `messages.due_reminders` | 毎日の DM の見出し、ラベル、相対日数、代替表示 |

Issue の更新通知の見出しには、更新した Redmine ユーザーを使います。Slack マークアップでの初期形式は `🔄 Kota *Issue updated*` です。プラグインを編集せずに、アイコンの後の文言を変更できます。

```yaml
messages:
  templates:
    issue_updated_header: '%{actor} *%{event}*'
```

`issue_updated_header` テンプレートは、コメントを含む Issue 更新にも適用されます。Issue の作成・削除、単独のコメント通知の見出しには、それぞれのイベント名を使います。操作者は Slack のメンションではなく名前で表示します。

その他のテンプレートは、カードを表示できないクライアント向けの attachment のプレーンテキスト代替表示を作ります。

| テンプレート | 適用対象 | 使用できるプレースホルダー |
| --- | --- | --- |
| `issue_updated_header` | Issue 更新通知の見出し | `%{actor}`, `%{event}` |
| `issue_fallback` | Issue の作成、コメントを伴わない更新、削除 | `%{project}`, `%{actor}`, `%{action}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `journal_fallback` | コメントを伴う Issue の変更と、単独の Issue コメント | `%{project}`, `%{actor}`, `%{event}`, `%{tracker}`, `%{id}`, `%{subject}` |
| `generic_fallback` | Wiki、News、News コメント、作業時間、Version、Project | `%{event}`, `%{subject}` |

たとえば `generic_fallback: '%{event}: %{subject}'` は、`News updated: Example title` を作ります。プレースホルダーは `%{name}` 形式で指定してください。不明なプレースホルダーを指定すると、そのテンプレートには組み込みの初期値を使います。

### 担当者のメンション

Issue の担当者が変わったとき、明示的な `users` の対応付けによって新しい担当者を Slack メンションにできます。

```yaml
users:
  # Redmine login or email address: Slack member ID
  alice: 'U0123456789'
```

`slack.auto_map_users_by_name: true` を設定すると、Redmine の**ログイン名**と、有効な人間の Slack ユーザーの `profile.display_name` またはアカウントの `name` が大文字・小文字を区別せず完全一致する場合にも、自動で対応付けられます。明示的な対応付けが優先されます。対応するユーザーがいない場合や複数いる場合は、Redmine の名前をそのまま表示します。ユーザー一覧は 10 分間キャッシュし、API エラー時も名前表示へ戻します。自動対応付けには `users:read` と、スコープ追加後のアプリ再インストールが必要です。メールアドレスは読み込まず、`users:read.email` は不要です。

新しい担当者には Slack の `<@U0123456789>` メンション形式を使います。Issue の作成者、Journal の作成者、Wiki の更新者、Issue 更新見出しの操作者には、自動メンションを付けず名前を表示します。

## 毎日の期日リマインダー DM

Redmine アプリケーションのタイムゾーンに合わせて、タスクを 1 日 1 回実行します。タスクは `slack` キューにジョブを登録し、ワーカーが DM を送ります。

```bash
cd /path/to/redmine
bundle exec rake redmine:slack:due_reminders RAILS_ENV=production
```

Redmine の運用環境で使用しているスケジューラーに、このタスクを 1 日 1 回登録してください。同じ日に再実行した場合も、その都度リマインダーが送られます。

cron から実行する場合は、先に Redmine のディレクトリへ移動する小さなスクリプトにコマンドを記述します。

```sh
#!/bin/sh
cd /path/to/redmine || exit 1
bundle exec rake redmine:slack:due_reminders days=7 RAILS_ENV=production
```

Redmine 標準のリマインダーコマンドと同じ絞り込みオプションを Rake の環境引数として指定できます。省略した条件では対象を絞り込みません。

| オプション | 内容 |
| --- | --- |
| `days` | 期日の何日前から通知するか。指定するとプロジェクト別設定を含む YAML の `due_reminders.days` より優先します。省略時は YAML の設定を使います（初期値: 3 日）。 |
| `tracker` | トラッカー ID。 |
| `project` | プロジェクトの ID または識別子。 |
| `users` | 担当 Issue を通知する Redmine ユーザー ID のカンマ区切り。大文字の `USERS` も使えます。 |
| `version` | 対象バージョン名。Redmine と同様に大文字・小文字を区別せず照合します。 |

たとえば、ユーザー 3 と 5 だけに絞る場合、またはすべての条件を組み合わせる場合は次のように実行します。

```bash
bundle exec rake redmine:slack:due_reminders users=3,5 RAILS_ENV=production
bundle exec rake redmine:slack:due_reminders days=7 tracker=2 project=example users=3,5 version="1.0" RAILS_ENV=production
```

指定したすべての条件に一致する Issue だけを対象にし、ワーカーも送信前に条件と担当者を再確認します。`USERS=3` や `USERS=3,5` も使えますが、`users` と `USERS` は同時に指定できません。値が無効な場合や指定したユーザー・トラッカー・プロジェクト・バージョンが存在しない場合は、ジョブを登録する前に停止します。同じ日に既に通知した Issue も、実行のたびに再送されます。

初期状態では、担当者がいる未完了の Issue を、期日の **3 日前から**期限超過後も毎日、Redmine のステータスが**終了**になるまで通知します。ワーカーは担当者ごとにコンパクトな DM を 1 通送り、リンク付き Issue を期限超過・本日期日・期日が近い課題の見出しでまとめます。各グループの色は独立しており、初期値は期限超過が赤、本日期日がオレンジ、期日が近い課題には設定済みの attachment 色を使います。Issue 行には日付を繰り返さず相対日数を示し、本日期日の見出しが日付の文脈を示します。100 件を超える場合は番号付きの複数メッセージに分割します。Bot Token または Slack ユーザーの対応付けが異なると、アプリごとに別の DM に分かれます。同じ日にタスクを再実行しても、その時点で対象となる Issue を送ります。

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

`due_reminders.colors.overdue`、`.today`、`.upcoming` には 6 桁の 16 進カラーコードを指定します。無効または省略した値は初期値を使います。`upcoming` を省略した場合は `slack.attachment_color` を使います。色は `projects.<identifier>.due_reminders.colors` でプロジェクトごとに上書きできます。

担当者は、Issue を閲覧できる有効な Redmine ユーザーであり、`users` または `slack.auto_map_users_by_name` で Slack ユーザーに対応付けられている必要があります。グループ担当者と対応付けのないユーザーはスキップし、ログに記録します。Redmine で担当者に閲覧権限がある場合は、非公開 Issue も本人への DM に含められます。DM 配信には `chat:write` と `im:write` を持つ Bot Token が必要です。プロジェクトのチャンネル ID は使いません。Slack アプリの設定で **App Home → Messages Tab → Display Messages tab** を有効にしてください。有効にしていないと、`conversations.open` が成功しても Slack が `messages_tab_disabled` を返します。スコープを追加した場合はアプリを再インストールしてください。スケジュールに依存する前に、テスト用の Issue が受信者の Slack DM に表示されることを確認してください。

DM の文言は YAML の `messages.due_reminders` 以下で変更できます。[設定例](config/redmine_slack_notification.yml.example)にすべてのキーとプレースホルダーを掲載しています。たとえば、他のグループを変更せずに見出しと期限超過グループのラベルを変更できます。

```yaml
messages:
  due_reminders:
    title: '📋 *Due reminders: %{count}%{suffix}*'
    overdue_label: '🚨 Overdue'
```

同じキーを `projects.<identifier>.messages.due_reminders` 以下でプロジェクトごとに上書きできます。

## 配信と運用

`RedmineSlackNotificationJob` は Redmine のイベント後、ActiveJob の `slack` キューに登録されます。Sidekiq を使う場合は、たとえば次のようにキューを設定します。

```yaml
:queues:
  - default
  - mailers
  - slack
```

Slack API の失敗はログに記録され、Sidekiq が再試行します。Redmine の操作はロールバックされません。通知の投稿に成功した後、一時的な画像プレビューの削除に失敗した場合は、重複投稿を避けるため、エラーを記録するだけでジョブを再試行しません。通知が届かない場合は、`RedmineSlackNotificationJob` と `RedmineSlackNotification` のログを確認してください。

開発環境では、ActiveJob の inline アダプターを使えば Sidekiq なしで実行できます。

```ruby
config.active_job.queue_adapter = :inline
```

inline 配信は Redmine のリクエスト中に実行されるため、Slack の応答が遅いとリクエスト時間が延びます。本番環境では `slack` キューを処理するワーカーを使ってください。

通知が届かない場合は、次の順に確認します。

1. 対象イベントのキーと親スイッチが、全体設定とプロジェクト設定で有効になっているか。
2. 実行中の Redmine と Sidekiq が意図した Token を使っているか。`SLACK_BOT_TOKEN` は YAML より優先されます。
3. プロジェクト識別子が意図したチャンネルに対応しているか、またはデフォルトのチャンネルが設定されているか。ボットがチャンネルに参加しているか。
4. Bot Token に `chat:write` があり、オプション機能に応じて `files:write` または `users:read` があるか。スコープの追加後にアプリを再インストールしたか。
5. Sidekiq が `slack` キューを処理しているか。ログでジョブと Slack API のエラーコードを確認してください。

YAML を変更した場合は Redmine と Sidekiq の両方を再起動してください。ジョブの投稿成功は API への配信を示します。実際の表示や画像は通知先のチャンネルで確認してください。既存のメッセージは更新されません。

## プライバシーと開発

チャンネル通知では、非公開 Issue と非公開 Journal のコメントを除外します。毎日の DM には、担当者が Redmine で閲覧できる非公開 Issue を含められます。非公開 Issue や非公開コメントの画像はアップロードしません。実際の `redmine_slack_notification.yml` をコミットしたり、Bot Token をログ・設定例・サポート依頼に載せたりしないでください。Token が漏れた場合は更新してください。

ローカルのテストスイートは次のコマンドで実行できます。

```bash
ruby -Itest test/image_notification_test.rb
```

テストはスタブを使って通知の整形と配信ロジックを確認します。Slack への投稿や稼働中の Redmine 環境は検証しません。
