[English](README.md) | [日本語](README.ja.md)

# Slackmine

通知機能からSlackとRedmineの統合へ機能が広がったため、**Redmine Event Notifications for Slack**（`redmine_slack_notification`）から **Slackmine** に改名しました。内部名・プラグインID・設定ファイル名・エンドポイントも `slackmine` に統一し、旧名の互換対応は設けていません。

Redmine 7 の Issue、Wiki、News、作業時間、Version、Project のイベントを Slack に通知するプラグインです。Issue の期日が近づいたとき、担当者に Slack DM で毎日リマインダーを送ることもできます。通知には Redmine の対象ページへのリンクと、色付きの Block Kit attachment を使います。配信は ActiveJob を経由し、通常は Sidekiq の `slack` キューで処理します。

このプラグインは通知、Work Object操作、任意のスラッシュコマンドを提供します。プロジェクト設定タブやRedmineのカスタムフィールドは追加しません。

## 機能一覧

| 機能 | できること |
| --- | --- |
| [Redmineのイベント通知](#イベントの切り替え) | Issueの作成・変更・コメント・削除と、Wiki、News、作業時間、Version、Projectのイベントを通知。全体またはプロジェクト単位でイベントごとに有効・無効を設定できます。 |
| [通知の表示設定](#通知内容) | 表示項目・色・文言の変更、本文の差分、Issueの画像表示、対応付けた担当者へのメンション。 |
| [プロジェクトの通知先選択](#親プロジェクトのチャンネルを継承する) | 明示したチャンネル、または任意の名前マッチングを使い、見つからなければ近い親から順に探索し、最後にデフォルトへ通知。プロジェクトごとにSlackアプリ／トークンも設定できます。 |
| [IssueのWork Objectプレビュー](#チケットの-work-object-previews) | Slack内にチケットカードと詳細を表示。表示項目を設定でき、詳細を開くと最新情報を取得します。 |
| [Slackからのチケット操作](#work-object-カードと詳細パネルからの操作) | 権限内でステータス・担当者・優先度・期日を変更し、コメント追加、自分への割り当て、作業開始・完了、ウォッチ登録・解除。作業時間の入力はRedmineのフォームを開きます。 |
| [コメント通知のスレッド化](#redmineコメント通知をスレッドにまとめる) | RedmineのIssueコメント通知をSlackのスレッドにまとめます。 |
| [Slackの返信をRedmineへ保存](#通知スレッドからredmineにコメントを追加) | 対応する通知スレッドへのテキスト・ファイルの返信を、対応付けたユーザー名義のRedmineコメント・添付として保存します。 |
| [スラッシュコマンド](#スラッシュコマンド) | チケット検索、担当・期日一覧、個人リマインダー、チケット作成、コメント追加、フォームや直接指定によるステータス・担当者変更。1件の結果は設定に応じてカード表示し、プレビュー無効時はテキストで表示します。 |
| [Slackメッセージからチケット作成](#slackメッセージからチケット作成) | メッセージメニューから権限のあるプロジェクトを選び、本文と投稿元リンクを引き継いだ作成フォームを確認して保存します。 |
| [Slackリンク取得・カード表示](#redmine本文内のslackリンクカード) | 説明・コメント内のSlackリンクから本文を取得し、既存の本文欄に検索可能な引用を保存。リンク位置にカードを表示し、名前解決とスレッド情報も表示します。 |
| [期日リマインダー](#毎日の期日リマインダー-dm) | 担当する未完了チケットの期限超過・設定期間内の期日をSlack DMでまとめて通知。定期実行は別途設定します。 |
| [App Homeのチケット一覧](#app-homeのチケット一覧) | 自分が更新した・今週期限・担当している・報告した未完了チケットを5列表で表示。フィルター変更で自動更新し、題名からRedmineを開き、編集ボタンから権限内で編集・コメント追加。 |
| [ユーザーの対応付け](#担当者のメンション) | RedmineユーザーとSlack IDの明示的な対応付け、送信時の名前マッチング、任意の[受信操作時のメールアドレス照合](#メールアドレスで閲覧ユーザーを自動対応付けする)。操作時にはRedmineの権限とワークフローを確認します。 |
| [個人ごとの通知メール抑止](#個人ごとの通知メール設定) | Slack通知設定とチャンネル参加が条件を満たす場合、本人が対象の通知メールを停止できます。アカウント・セキュリティ関連メールは継続し、Slackの配信成功は確認しません。 |

Work Objectのプレビュー・操作、スラッシュコマンド、スレッド連携、リマインダーには、それぞれの設定とSlackアプリのスコープ・イベント設定が必要です。個人のメール抑止設定は初期値OFFです。設定方法と制限は各リンク先を参照してください。

以下の画像は、実装で対応している表示内容と操作を架空の英語データで示した機能イメージです。実画面やSlackのレイアウトを完全に再現したものではなく、周辺のナビゲーションは省略しています。設定例は設定画面ではなくYAMLで示しています。英語版・日本語版で同じ画像を使用しています。

## 要件とセットアップ

- Redmine 7.0 以降。
- Bot Token と [`chat:write`](https://docs.slack.dev/reference/methods/chat.postMessage/) スコープを持つ Slack アプリ。期日リマインダーの DM には [`im:write`](https://docs.slack.dev/reference/methods/conversations.open/)、Issue の画像を本文内に表示するには [`files:write`](https://docs.slack.dev/reference/methods/files.getUploadURLExternal/)、名前によるユーザーの自動対応付けには [`users:read`](https://docs.slack.dev/reference/methods/users.list/) も必要です。スコープを変更したら、Slack アプリを再インストールして Bot Token に反映してください。
- [個人の通知メール抑止](#個人ごとの通知メール設定)でユーザーの自動マッチングを使う場合は、`users:read`と`users:read.email`の両方を追加し、Slackアプリを再インストールしてください。
- プロジェクトごとの通知先チャンネル、またはデフォルトのチャンネル。非公開チャンネルを含め、通知先にはボットを招待してください。
- 期日リマインダーの DM を使う場合は、Slack アプリの **App Home → Display Messages tab** を有効にしてください。
- `slack` キューを処理する ActiveJob ワーカー。本番環境では Sidekiq を推奨します。

1. このディレクトリを Redmine の `plugins/slackmine` に配置します。
2. [設定例](config/slackmine.yml.example)を Redmine アプリケーションの `config/slackmine.yml` にコピーします。
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

1. `<Redmine root>/config/slackmine.yml`
2. `plugins/slackmine/config/slackmine.yml`

最上位の設定グループ `slack`、`events`、`messages`、`users`、`due_reminders` は、`projects.<identifier>` 以下で上書きできます。ネストしたマップはキーごとにマージされ、省略したプロジェクト設定は全体設定を引き継ぎます。`false` を明示すると、全体設定の `true` を上書きします。Bot Token の優先順位は、`projects.<identifier>.slack.bot_token`、`SLACK_BOT_TOKEN`、全体の `slack.bot_token` の順です。チャンネルは、`projects.<identifier>.slack.default_channel_id`、従来の `projects.<identifier>.channel_id`、子自身の名前による自動照合の順に確認します。見つからなければ近い親から同じ順序で確認し、最後に全体の `slack.default_channel_id` を使います。プロジェクトのキーには表示名ではなく Redmine の**識別子**を使います。Token またはチャンネルがない場合、通知は送られずログに記録されます。チャンネル ID は通常、公開チャンネルが `C`、非公開チャンネルが `G` で始まります。プロジェクト固有の Token も Git に含めず、YAML の変更後は Redmine と Sidekiq を再起動してください。

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

![イベントの切り替え](docs/images/features/event-notifications.webp)

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

同じキーでは、プロジェクト固有の値が全体の値より優先されます。全体で無効にした `issue.updated.enabled` をプロジェクトで上書きする場合は、親スイッチもそのプロジェクトで有効にしてください。従来のフラットなキー `status_changed`、`comment_added`、`issue_updated` なども両方の階層で使えます。同じ階層では、ネストしたキーが対応するフラットなキーより優先されます。従来のフラット設定では、`issue_updated` が親スイッチと `other_changed` の両方を制御します。[設定例](config/slackmine.yml.example)にネストした設定の全体を掲載しています。

Wiki ページ、News、作業時間、Version の削除通知は、後から追加されたため初期状態では無効です。削除されたレコードのページは存在しないため、削除通知のリンクは所属するプロジェクトのページを指します。

## 通知内容

![通知内容](docs/images/features/notification-formatting.webp)

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

### チケットの Work Object Previews

![チケットの Work Object Previews](docs/images/features/work-object-previews.webp)

`slack.work_object_previews: true` にすると、公開 Issue の作成・更新・コメント通知に Slack の **Task Work Object** メタデータを追加します。省略時と `false` は従来の通知です。既存のイベント本文・変更差分・色付きカード・画像を維持し、Work Object のカードを追加表示できるようにします。Issue の削除通知、Wiki などの通知、毎日の期日リマインダー DM には追加しません。

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

全体設定を `false` にして特定プロジェクトだけ `true` にすることもできます。YAML の変更後は Redmine と Sidekiq を再起動してください。

Slack アプリの管理画面でも **Work Object Previews → ON → Task を選択 → Save** を設定してください。ワークスペース側でプレビューが制限されている場合は、その設定も確認してください。通知は既存の `chat.postMessage` で送信します。通知プレビューだけのために新しいイベント購読やリンク展開のスコープを追加する必要はありません。[Slack の実装仕様](https://docs.slack.dev/messaging/work-objects-implementation/#notifications-implementation)

件名・チケット番号・トラッカーを Work Object の見出しに使います。ステータス、優先度、担当者、作成者、期日は `slack.metadata.issue` で表示が有効な場合だけ標準フィールドとして送ります。プロジェクト、トラッカー、カテゴリ、更新者、対象バージョンも同じ表示設定に従ってカスタムフィールドとして送ります。ラベルには `messages.fields` を使います。それ以外の項目と説明文・コメント本文は既存の通知カードで表示します。担当者・作成者は表示名を使い、Work Object 用に新たなメンションやユーザー一覧取得を行いません。

チケットの URL の SHA-256 値を `external_ref.id` に使い、Slack の ID 文字制限を満たしながら、同じチケットの作成・更新・コメントで共通の識別子を送ります。別の Redmine の同番号チケットとは区別されます。Redmine のホスト名を変更すると識別子も変わります。リンク先の `url` は元のチケット URL のままです。

通知カードは**通知を生成した時点の情報**です。カードを開いたときと詳細パネルの再読み込み時には、`entity_details_requested` を受け取り、`entity.presentDetails` で最新のチケット情報を返します。[Slack の詳細表示 API](https://docs.slack.dev/reference/methods/entity.presentDetails/)

Slack標準のWork Object再読み込みは `link_shared` と `chat.unfurl` で処理します。`links:read`・`links:write`、`link_shared` の購読、**App unfurl domains**へのチケットURLのホスト登録を設定し、権限・ドメイン変更後にアプリを再インストールしてください。`cannot_unfurl_url` が出る場合は、**ワークスペースの設定と権限 → 添付 → ブロックされたプレビュー**を確認してください。対象ドメインがブロックされていると、権限が正しくても新規展開・再読み込みが失敗します。[Slack の更新イベント仕様](https://docs.slack.dev/reference/events/link_shared/)

詳細表示を使う場合は、次の設定を追加してください。`signing_secret` は Slack アプリの **Basic Information → App Credentials → Signing Secret** の値です。Bot Token とは別の値です。環境変数 `SLACK_SIGNING_SECRET` でも指定できます。

```yaml
slack:
  work_object_previews: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # 実際のSlackメンバーIDに置き換える
```

1. コードと YAML を配置し、Redmine と Sidekiq を再起動します。Sidekiq が `slack` キューを処理していることを確認してください。
2. Slack アプリの **Event Subscriptions → Enable Events** を ON にします。Request URL を `https://redmine.example.com/slackmine/events` にし、**Verified** を確認します。別のサーバーでは Redmine の公開 URL に合わせてください。サブディレクトリ配置の場合は、そのパスも含めます。
3. **Subscribe to bot events** に `entity_details_requested` を追加し、**Save Changes** します。このイベントと `entity.presentDetails` に追加 OAuth スコープは不要です。
4. チャンネルの Work Object カードを開き、ステータス・担当者・期日・説明文を確認します。Redmine で変更後、詳細パネルを再読み込みし、最新値になることを確認します。新しい通知を送る必要はありません。

要求の署名・タイムスタンプ・アプリとワークスペースを検証してから、既存の `slack` キューで応答します。閲覧ユーザーは `users` の明示的なログイン名／メールアドレスと Slack ID の対応付け、または有効な `auto_map_users_by_email` のメール一致で確認します。`auto_map_users_by_name` は閲覧許可に使いません。未対応付け・ロック済み・閲覧権限なしのユーザー、非公開チケット、無効なプロジェクト、`work_object_previews: false` のプロジェクトには内容を返さず、アクセス制限を表示します。プロジェクト別の Slack アプリでは `projects.<identifier>.slack.events` と `users` を上書きできます。

権限確認後の詳細には、最新の件名・チケット番号・トラッカー・プロジェクト・状態・優先度・担当者・作成者・期日・作成／更新日時・説明文（最大10,000文字）を返します。詳細表示の項目は通知用の `slack.metadata.issue` 設定とは独立しています。既存コメントや Redmine カスタムフィールド、貼り付けたリンクの自動展開は含みません。編集は下記の設定で有効にできます。

失敗時は Redmine／Sidekiq ログの `Work Object details failed` または `Work Object unfurl failed` に Slack API のエラーコードを記録します。読み取り成功時の調査用ログは出力しません。`missing_interactivity_url` が返る場合は、Slack アプリの **Interactivity & Shortcuts** の Request URL を設定してください。

### Work Object カードの表示項目

カード内の項目は `work_object_fields` のYAML記載順に表示します。`false` の項目と空の項目は飛ばします。Description／Last commentの末尾固定はありません。プロジェクト別設定がある場合は、その記載順を先に使い、引き継いだ項目を全体設定の順で後ろに追加します。

`slack.work_object_fields` でカード本体の全対応項目を個別に表示・非表示にできます。`true` が表示、`false` が非表示です。省略した項目は非表示です。この設定は `work_object_actions` や通知本文の `metadata.issue` より優先します。項目が空なら表示しません（担当者は「未割当」、進捗は `0%` も表示）。進捗はバーではなく正確な％表示です。

設定全体を省略した場合はカード本体の項目を表示しません。`projects.<identifier>.slack.work_object_fields` でプロジェクト別に上書きできます。対象はメインカードの項目で、必須の件名・チケット番号、右ペインの詳細・編集権限は変更しません。

```yaml
slack:
  work_object_fields:
    status: true
    assignee: true
    priority: true
    due_date: true
    category: true
    done_ratio: true
    project: false
    tracker: false
    author: false
    updater: false
    target_version: false
    start_date: false
    estimated_hours: false
    description: false
    last_comment: false
```

`last_comment: true` は最後の公開コメントの投稿者・ISO 8601日時・本文を表示します。非公開・空のコメントは除外し、本文は1,000文字で省略します。最後のコメントが通知本文と完全一致し、省略がない場合のみ本文側の重複を除きます。編集・削除差分は残します。カード再読み込み時に最新の公開コメントを取得します。

`description: true` でカードに説明文を表示します。空欄は非表示、1,000文字を超える場合は省略します。右ペインの説明全文は従来どおりです。

表示文言の既定値は英語です。`messages.work_objects` でボタン・編集画面・エラー文言、`messages.fields` で編集項目名、`messages.values.unassigned` で未割当表示を変更できます。全キーを設定例に掲載しています。`edit_title` と `edit_failed` は `%{id}` を使用できます。Slack自身が表示する標準項目名・メニューはSlackの言語設定に従います。

カードの「外部サービスで開く」は課題URLを開きます。`messages.work_objects.open_issue: '%{product_name}で開く'` で表示名を指定できます。

メインカードの「コメントを追加」はコメント専用モーダルを開きます。コメント追加権限を確認し、課題の各属性は変更しません。右ペインの編集操作は引き続き利用できます。表示名は `messages.work_objects.add_comment` で設定します。

### Work Object カードと詳細パネルからの操作

![Work Object カードと詳細パネルからの操作](docs/images/features/issue-actions.webp)

担当者は「課題を編集」から、割り当て可能なRedmineユーザーと「未割当」を選べます。詳細パネルのAssigneeも編集できます。保存時に閲覧・編集権限と割り当て可能なユーザーを再確認します。

Work Objectが表示される通知では、上部の重複見出し、本文中の件名リンク、カードにも表示されている現在値を省きます。コメント・説明・変更前後の差分・カードにない項目は残します。通知本文の整理は新しい通知から適用されます。

`slack.work_object_actions: true` を設定すると、Work Object が有効なすべての公開チケットのメインカードにステータス・担当者（未割当の場合も表示）・優先度・期日と「コメントを追加」「外部サービスで開く」を表示します。`work_object_actions: false` で操作を無効にします。「課題を編集」はSlackのモーダルを開き、権限に応じてステータス・担当者・優先度・期日・コメントを変更できます。既定では無効です。Slack アプリの **Interactivity & Shortcuts** を有効にし、Request URL を `https://redmine.example.com/slackmine/interactions` に設定します。署名検証には上記の `slack.events` 設定を共用します。

```yaml
slack:
  work_object_previews: true
  work_object_actions: true
```

公開済みのカードに埋め込まれた項目・ボタンは自動更新されないため、そのカードは再通知または元のメッセージの更新が必要です。詳細パネルの情報は開くたびに最新のチケットを取得します。

詳細パネルからも、許可されたステータス・優先度・期日を編集し、任意でコメントを追加できます。モーダルの担当者欄には割り当て可能なユーザーと「未割当」を表示します（候補が99人以下の場合）。「自分に割り当てる」は、すでに本人が担当者なら変更しません。操作を受信した後もSlackユーザーとRedmineユーザーの対応、チケットの公開・閲覧・編集権限、遷移可能なステータス、有効な優先度、割り当て可能なユーザーを再確認します。操作結果は元のカードまたは詳細パネルへ反映します。保存後にSlack側のカード更新が失敗しても、Redmineへの書き込みは再実行しません。

Work Object の「会話」表示は Redmine のコメント履歴とは別で、既存コメントは表示されません。操作が有効なチケットでは、詳細パネルの編集フォームから新規コメントを追加できます。通知スレッドからのコメント追加は、次の設定で利用できます。

### Work Object ボタンの選択と順序

`slack.work_object_buttons` の `true/false` と記載順で、カード・詳細パネルの操作を選べます。設定がある場合、省略したボタンは非表示です。設定全体を省略すると従来のボタン構成を維持します。プロジェクト別設定のキーを先に並べ、継承したキーを後に並べます。

```yaml
slack:
  work_object_actions: true
  work_object_buttons:
    add_comment: false
    open_issue: false
    edit_issue: false
    change_assignee: false
    assign_to_me: false
    start_work: true
    complete_work: true
    log_time: false
    watch: false
  work_object_start_status_id: 3
  # Completion status ID; use the actual completed status from your workflow.
  work_object_complete_status_id: 5
```

exampleは作業開始・作業完了だけを有効にし、開始先IDを3、完了先IDを5にしています。実際のRedmineワークフローに合わせてIDを変更してください。

| キー | 操作 |
| --- | --- |
| `add_comment` | コメント専用モーダル |
| `open_issue` | 外部サービスの課題URLを開く |
| `edit_issue` | 課題編集モーダル |
| `change_assignee` | 担当者専用モーダル |
| `assign_to_me` | 操作したユーザーに割り当て |
| `start_work` | `work_object_start_status_id` の状態へ遷移 |
| `complete_work` | `work_object_complete_status_id` の完了状態へ遷移 |
| `log_time` | Redmineの作業時間登録画面を開く。登録はその画面で行う |
| `watch` | 本人のウォッチ登録・解除 |

先頭2個は主ボタン、続く5個は「その他」メニューです。最大7個まで表示し、超過分は表示せず警告ログを出します。作業開始・作業完了は遷移先ID未設定・到達済みなら非表示です。両方を有効にすると、開始前は「作業開始」、設定した開始ステータスでは「作業完了」だけ表示します。完了先ステータスまたはRedmineの終了ステータスでは両方を非表示にします。両方のステータスIDを指定してください。片方だけ有効な場合は従来どおり独立して表示します。どちらも押下時にRedmineのワークフローと編集権限を再確認します。完了先IDは実際の完了ステータスを指定してください。右ペインでは編集権限・担当者・ウォッチ状態に応じて不要な操作を除きます。共有カードはユーザーごとに表示を変えられないため、個人の権限・状態は操作時に確認します。作業時間登録はRedmine側の権限・必須項目に従います。表示名は同名の `messages.work_objects` キーで上書きできます。

Description（説明）は、Redmineで本人に `description` の編集権限がある場合、Work Objectの詳細パネルとチケット編集フォームから変更できます。空白・Markdownを含む元の本文を入力欄に渡します。Slackの入力上限は3,000文字のため、それを超える既存の本文は読み取り専用とし、フォームにRedmineの全項目編集画面へのリンクを表示します。保存のために本文を短縮することはありません。空欄にすると説明を削除できます。保存時も権限を再確認し、通常のRedmineの変更履歴・通知に従います。

`watch: true` で登録・解除の両方が有効になります。共有カード・右ペインのどちらも、押下時に「ウォッチ設定」で本人の現在状態と登録／解除ボタンを表示します。古いウォッチ／解除ラベルが残っていても、現在の状態から操作を選び直します。フォームを開いただけでは変更しません。Slackのフォーム表示用トリガーの期限切れを避けるため表示は同期処理とし、確認後の保存はSlackキューで行います。入力欄のない確認フォームにも対応します。独立した `unwatch` 設定は不要です。表示文言は `messages.work_objects` の `watch_settings`、`watching`、`not_watching`、`watch`、`unwatch` で指定できます。

### メールアドレスで閲覧ユーザーを自動対応付けする

`slack.auto_map_users_by_email: true` にすると、Slackユーザーのメールアドレスと、有効なRedmineユーザーの登録メールアドレス（追加メールも含む）が一意に一致した場合、Work Object詳細表示とSlackからのコメント登録に利用できます。大文字・小文字は区別しません。既存の `users` 設定を優先し、無効・ロック済み・曖昧な設定や、別のSlackユーザーへの明示的な割り当てをメール一致で迂回しません。チケットの閲覧・コメント権限も引き続き確認します。

```yaml
slack:
  auto_map_users_by_email: true
```

Bot Tokenに `users:read` と `users:read.email` の両方を追加し、アプリを再インストールしてください。権限確認ごとに `users.info` で最新のユーザー情報を取得します。メール未取得・複数の有効ユーザーに一致・無効ユーザー・Bot・削除済みSlackユーザー・別ワークスペースのユーザー・APIエラー時は自動許可しません。設定された `slack.events.team_id` とSlackユーザーのワークスペースが一致する必要があります。メール情報はキャッシュせず、追加テーブル・Redis・ファイルへの保存や診断ログへの出力も行いません。`projects.<identifier>.slack.auto_map_users_by_email` で上書きできます。

名前による `auto_map_users_by_name` は送信時のメンションと期日リマインダーの対応付け用です。メール一致は受信側の詳細閲覧・コメント権限確認用であり、送信時のメンションやDMを自動的に有効化するものではありません。

### 親プロジェクトのチャンネルを継承する

![親プロジェクトのチャンネルを継承する](docs/images/features/channel-routing.webp)

各階層で `slack.default_channel_id` または従来の `channel_id`、次にプロジェクト表示名と同名の既存Slackチャンネルを確認します。子自身から始め、見つからなければRedmineの実際の親階層を近い順にたどります。どこにもなければ全体のデフォルトチャンネルを使います。子に同名チャンネルがなく、親に対応する既存チャンネルがある場合、子のチャンネルIDをYAMLへ繰り返し記入する必要はありません。子自身の名前一致は祖先の明示設定より優先します。

継承するのは送信先チャンネルだけです。Bot Token・イベント・文言・ユーザー対応付け・リマインダーは従来の全体／個別設定の規則を維持します。子で使うBotが選択先のチャンネルに参加している必要があります。親階層を変更すると継承先も変わります。名前検索には子の `slack.auto_map_channels_by_name: true` が必要で、各祖先の自動照合にもそのプロジェクトの設定を使います。子で `false` にすると祖先を含めた名前検索を無効化しますが、祖先の明示的なチャンネル指定は引き続き参照します。

```yaml
projects:
  parent-project:
    channel_id: 'C0123456789'
  # チャンネルを個別指定しない子は、この親のチャンネルを使います。
```

### プロジェクト名とチャンネル名の自動マッチング

`slack.auto_map_channels_by_name: true` で、Redmineプロジェクトの**表示名**とSlackチャンネル名を自動照合できます。前後の空白と大文字・小文字の違いを無視し、空白はハイフンに変換します（`Customer Support` → `customer-support`）。プロジェクト識別子は照合に使いません。曖昧な部分一致、チャンネル作成、自動参加は行いません。

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

各プロジェクトで `slack.default_channel_id`、旧形式の `channel_id`、一意な名前一致の順に確認します。子自身、近い親から順に祖先を確認し、最初に見つかったチャンネルを使います。どの階層にもなければ共通の `slack.default_channel_id` を使います。一致なし・複数候補・APIエラー時は共通の通知先に戻り、共通設定もなければ通知をスキップしてログに記録します。スイッチはプロジェクト別に上書きできます。

`users.conversations` でBotが参加しているチャンネルだけを取得します。公開チャンネルには `channels:read`、非公開チャンネルには `groups:read` を追加し、アプリを再インストールしてください。スレッド通知に使う `*:history` とは別のスコープです。アーカイブ済みチャンネルとDMは除外します。一覧はBot Token別にプロセスのメモリへ10分間キャッシュし、DB・Redis・ファイル・Railsキャッシュには保存しません。名前・参加状態の変更が反映されるまで最大10分かかり、ワーカーの再起動でキャッシュは消えます。取得は200件ずつ最大10ページに制限し、不完全な一覧や取得失敗時は自動照合に使いません。キャッシュはワーカーごとに独立します。

コメント通知のスレッド投稿とSlackからのコメント登録にも自動判定を適用します。共通スイッチがONならプロジェクト別のYAML設定は不要です。返信の権限確認と、明示的なユーザー対応付けまたは有効なメール自動照合は引き続き必要です。

### Redmineコメント通知をスレッドにまとめる

![Redmineコメント通知をスレッドにまとめる](docs/images/features/comment-threads.webp)

`slack.comment_notifications_in_threads: true` にすると、コメントだけの追加・編集・削除通知を、設定したチャンネル内の同じチケットの最新通知スレッドに投稿します。省略時・`false` は従来どおりチャンネルに投稿します。有効なチケット項目の変更も含む更新はチャンネルに投稿します。スレッドが見つかった場合、新規コメントは設定可能な見出しと書式付きの本文を表示し、チケットリンク・完全なイベントカード・Work Objectプレビューは繰り返しません。編集は設定された本文・差分表示、削除は削除差分を維持し、画像も引き続き扱います。通常のチャンネル投稿に戻る場合は完全な通知形式を使います。`slack.thread_comments` やWork Object Previewsとは独立した設定です。

```yaml
slack:
  comment_notifications_in_threads: true
  events:
    app_id: 'A0123456789'
```

`projects.<identifier>.slack.comment_notifications_in_threads` でプロジェクト別に上書きできます。Botのチャンネル参加と、非公開チャンネルでは `groups:history`、公開チャンネルでは `channels:history` が必要です。スコープ追加後はアプリを再インストールしてください。`slack.events.app_id` でこのアプリの通知を識別します。コメント通知の送信だけならEvent Subscriptionの追加は不要です。

簡易通知の見出しは `messages.thread_notifications.added_header`・`updated_header`・`deleted_header` で変更できます。`%{product_name}`・`%{id}`・`%{actor}`・`%{subject}` を利用でき、`projects.<identifier>.messages` でプロジェクト別に上書きできます。既定値と設定例は英語です。見出しとコメント本文を分け、本文は一度だけ表示します。見出し内の `#%{id}` は、そのチケットのRedmineページへのリンクになります。

```yaml
messages:
  thread_notifications:
    added_header: '%{product_name} #%{id}: New comment'
    updated_header: '%{product_name} #%{id}: Comment updated'
    deleted_header: '%{product_name} #%{id}: Comment deleted'
```

通知ごとに履歴を最大3ページ、各ページ100件を要求して検索します（Slackが返す件数は少ない場合があります）。設定したアプリの最上位通知で、件名のチケットURLが完全一致するものだけを対象にします。利用者の投稿、コメント本文中のリンク、チャンネルにも送信されたスレッド返信は対象外です。見つからない場合、アプリID未設定、履歴取得エラー時は通常のチャンネル投稿に戻ります。DB・Redis・ファイルにスレッドの対応表は保存しません。会話開始時と最新通知のスレッドが異なる場合があり、検索範囲外の古い通知には戻れません。履歴取得による遅延とSlack API利用回数が増えます。既存の通知は移動しません。

### 通知スレッドからRedmineにコメントを追加

![通知スレッドからRedmineにコメントを追加](docs/images/features/thread-replies.webp)

Work Objectカードは、Slackがカードを準備している間、履歴APIで`from_url`と添付IDだけの形式になることがあります。この簡略形式も、アプリの投稿であることを確認した親通知のfallbackにある最初のチケット番号と、唯一の正規カードURLが一致する場合に識別します。不一致・曖昧な参照は取り込みません。コメント保存成功時は同じSlackスレッドに確認メッセージを返します。

`slack.thread_comments: true` にすると、このプラグインが送った Issue 通知へのテキスト・ファイルの返信を、返信者本人の Redmine コメントとして登録します。省略時・`false` は無効です。Work Object Previews は必須ではありません。

```yaml
slack:
  thread_comments: true
  events:
    app_id: 'A0123456789'
    team_id: 'T0123456789'
    signing_secret: 'REPLACE-ME'
users:
  alice: 'U0123456789' # 実際のSlackメンバーID
projects:
  another-project:
    slack:
      thread_comments: false
```

Slack 側では非公開チャンネル用の Bot Token スコープ `groups:history` とイベント `message.groups` を追加してください。公開チャンネルの場合は `channels:history` と `message.channels` を使います。スコープ追加後はアプリを再インストールします。署名検証と Request URL は詳細表示と共通です。Bot が対象チャンネルに参加している必要があります。[Slack のメッセージイベント](https://docs.slack.dev/reference/events/message/)

ファイル付き返信（ファイルだけの投稿も含む）にはBot Tokenスコープ `files:read` が必要です。追加後にアプリを再インストールしてください。PDF・Office文書・圧縮ファイル・テキストなど、SlackにアップロードされたファイルをBot認証で取得し、返信者名義の通常のRedmineチケット添付として保存します。PNG・JPEG・GIF・WebPは検証して画像表示し、それ以外（SVG・動画を含む）は `attachment:"ファイル名"` の記法で保存し、ファイル名からRedmineの添付表示ページへリンクします。プレビューの可否はRedmineとファイル形式に依存します。取り込み時に添付IDをSlack引用の保存情報へ記録し、明示的に対応付けた添付だけを本文と「Open in Slack」の間にまとめます。通常のコメントや、この対応情報がない過去の返信は従来の表示を維持します。カードが表示されない場合は出典URLの下に添付参照を表示します。画像は添付ファイル名で参照し、`@2x`も維持してRedmineの画像サイズ補正を適用します。1返信につき最大10ファイル、1ファイルは10 MiBとRedmineの添付サイズ上限の小さい方まで、合計50 MiBまでです。Redmineの添付権限・拡張子制限も適用します。コメントと添付は同じトランザクションで保存し、取得・検証に失敗した場合はコメントだけを残しません。再送で保存済み添付を重複登録しません。外部ファイルは非対応です。ファイルの拒否時は失敗を返信し、一時的なAPI・通信エラーはジョブで再試行します。

追加テーブル・DBマイグレーション・Redisへの処理済みID保存は不要です。返信先の親通知1件だけを `conversations.history` で取得し、アプリIDとチケット見出しの正規URLを検証します。対象は現在の設定で通知先になっているチャンネルです。既存の通知にも返信できますが、他のアプリ・ユーザーの投稿や任意のチケットリンクへの返信は登録しません。

`users` に明示的に対応付けた、または有効なメール自動照合で特定したユーザーについて、チケットの閲覧権限とトラッカーを含むコメント追加権限を確認します。非公開チケット・無効なプロジェクト・未対応付けユーザーは拒否します。返信の本文は最大10,000文字まで受け付けます。コメントには元メッセージへのURLを保存し、リンクカードが有効なら既存の引用取り込み処理で本文を保存・カード表示します。既存のJournalの `created_on` と `updated_on` の両方にSlackの元の投稿時刻を設定し、浮動小数点を経由せずマイクロ秒まで保持します。新規取り込み時には「編集済み」を付けず、その後Redmineで編集した場合は通常どおり編集日時が更新されます。同じチケット・対応付けた投稿者・投稿時刻のコメントがあれば再送と判断します。既存のチケット行ロック中に重複確認と保存を行います。追加テーブル・カラム・Redisへの状態保存・状態ファイルは不要です。本文をRedmineで編集しても重複判定は維持されます。旧バージョンの出典行付きコメントも重複確認の対象です。

正確な重複判定には、既存の `journals.created_on` がマイクロ秒（小数点以下6桁）を保持できることが必要です。日時の精度が低い環境では、同じ投稿者の別の返信を重複と判断する場合があります。同じチケット・対応付けた投稿者・完全に同じ投稿時刻の別コメントも重複と判断します。コメントを削除したり、投稿者や投稿時刻を変更したりすると、その返信の重複判定はできなくなります。既存コメントの出典行は自動では削除しません。

Work Objectのカードや詳細ヘッダー、「〜で開く」に使うサービス名は `messages.work_objects.product_name` で変更できます（既定値: `Redmine`）。返信結果の文言には `%{id}` と `%{product_name}` を使えます。成功・拒否の確認メッセージ内の `#%{id}` もチケットへのリンクになります。すべて `projects.<identifier>.messages` でプロジェクト別に上書きできます。

```yaml
messages:
  work_objects:
    product_name: 'Example Tracker'
  thread_comments:
    saved: '✅ Comment added to %{product_name} #%{id}.'
    restricted: '⚠️ Could not add the comment. Check your permissions.'
```

設定変更は新しい通知と再取得した詳細に反映されます。既存の通知カードは書き換えません。「詳細」「会話」などSlack側のUI文言はSlackの言語設定に従います。

保存結果は同じスレッドに返します。文言は `messages.thread_comments.saved`（`%{id}` と `%{product_name}` を利用可）と `messages.thread_comments.restricted` で変更できます。ファイルの拒否時は `messages.thread_comments.image_failed` を使います。成功コメントの通常のSlack通知は抑制しますが、Redmineの標準メール通知等は通常どおり動きます。Bot投稿・Slackでの編集／削除は同期しません。取得不能・サイズ超過・無効なファイルを含む返信は全体を拒否します。Slackのメンションやリンク表記をRedmine形式へ変換する処理も含みません。保存後の結果返信に失敗してもコメントは残り、ログに記録します。スイッチをOFFにしても既に登録されたコメントは残ります。

コード・YAMLの反映後、RedmineとSidekiqを再起動してください。テスト用チケットの通知へ返信し、本人名義のコメント本文と成功返信を確認します。権限のないユーザー、Bot返信、Slack側での編集も試し、コメントが増えないことを確認してください。

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

最上位の `messages` ツリーで通知文言を変更できます。イベントを送るかどうかは制御しません。すべてのキーは任意です。省略した値や空文字列には組み込みの初期値を使います。[設定例](config/slackmine.yml.example)には、使用できるすべてのキーとサンプル値を掲載しています。

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

Issue の更新通知の見出しには、更新した Redmine ユーザーを使います。Slack マークアップでの初期形式は `🔄 Alice *Issue updated*` です。プラグインを編集せずに、アイコンの後の文言を変更できます。

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

![担当者のメンション](docs/images/features/user-mapping.webp)

Issue の担当者が変わったとき、明示的な `users` の対応付けによって新しい担当者を Slack メンションにできます。

```yaml
users:
  # Redmine login or email address: Slack member ID
  alice: 'U0123456789'
```

`slack.auto_map_users_by_name: true` を設定すると、Redmine の**ログイン名**と、有効な人間の Slack ユーザーの `profile.display_name` またはアカウントの `name` が大文字・小文字を区別せず完全一致する場合にも、自動で対応付けられます。明示的な対応付けが優先されます。対応するユーザーがいない場合や複数いる場合は、Redmine の名前をそのまま表示します。ユーザー一覧は 10 分間キャッシュし、API エラー時も名前表示へ戻します。自動対応付けには `users:read` と、スコープ追加後のアプリ再インストールが必要です。担当者メンションの対応付けではメールアドレスを読み込まず、`users:read.email` は不要です。[個人の通知メール抑止](#個人ごとの通知メール設定)にも名前の自動マッチングを使う場合は、本人確認のため`users:read.email`も必要です。

新しい担当者には Slack の `<@U0123456789>` メンション形式を使います。Issue の作成者、Journal の作成者、Wiki の更新者、Issue 更新見出しの操作者には、自動メンションを付けず名前を表示します。

## Slackメッセージからチケット作成

![Slackメッセージからチケット作成](docs/images/features/message-to-issue.webp)

Slackアプリの **Interactivity & Shortcuts** でInteractivityを有効にし、Request URLを `https://redmine.example.com/slackmine/interactions` に設定します。**メッセージショートカット**を追加し、Callback IDを `slackmine_message_create`、名前を「チケットを作成」などにします。Botスコープに `commands` を追加し、スコープを変更した場合はアプリを再インストールしてください。[スラッシュコマンド](#スラッシュコマンド)の連携設定を共用するため、`slack.slash_command`、グローバルBot Token、署名シークレット、app/team ID、ユーザー対応付けが必要です。Work Objectプレビューは任意です。

メッセージの「その他のアクション」からショートカットを実行し、プロジェクトを選択します。次のフォームでトラッカー・題名・説明を確認して保存します。最初の空でない行を題名にし、説明には本文と `chat.getPermalink` で取得した投稿元リンクを入れます。スレッド返信からも使用できますが、コピーするのは選択したメッセージだけです。通常の本文が空の場合は、Block Kitや添付カードのタイトル・本文・項目からテキストを取り込みます。添付ファイル・スレッド全体・AI要約は取り込みません。Slackの本文の書式記法はそのまま残ります。題名は255文字、説明は投稿元リンクを含め3,000文字までに短縮するため、保存前に確認してください。

候補は、対応付けられたユーザーにチケット作成権限があり、app/team連携が一致する有効なプロジェクトを最大100件表示します。投稿元チャンネルに対応するプロジェクトを先に並べます。次のフォームと保存時にも権限・トラッカーを確認します。メニューを開いたりプロジェクトを選んだりしただけでは作成しません。必須カスタムフィールドがある場合はRedmineの全項目フォームへのリンクを使用しますが、そのリンク先には下書きは引き継ぎません。保存は既存のチケット作成処理を使い、キャッシュによる再送対策と通常の通知が適用されます。

選択した本文は既存の `Rails.cache` に、実行ユーザーとapp/teamに紐付けて30分間保持します。作成フォームに切り替えた後はフォーム内に下書きが保持されます。プロジェクト選択時にキャッシュが期限切れ・消失した場合は、ショートカットを開き直してください。複数Webワーカーでは共有キャッシュまたは同一ワーカーへの振り分けが必要です。追加テーブルやキャッシュサービスは導入しません。フォーム表示・切り替えは同期処理でSlackの3秒制限があるため、配備後に実際のアプリで確認してください。プライベートチャンネルやDMの本文も、他のメンバーが閲覧できるプロジェクトに転記できます。保存前に作成先と内容を確認してください。

## App Homeのチケット一覧

![App Homeのチケット一覧](docs/images/features/app-home.webp)

一覧は5列の表で、題名リンク（その下にプロジェクト）、ステータス、担当者、期日、編集ボタンを表示します。題名は最大200文字でブラウザーを開き、編集ボタンは権限に応じたSlack内のフォームを開きます。区分ごとの見出しは1つにし、最大10件を5件ずつ表示します。列幅とモバイルでの描画はSlackが決定します。区分の文言は `messages.app_home`、属性のラベルは `messages.fields`、編集ボタンは `messages.work_objects.edit_issue` で変更できます。ホームを開き直しても、最後に選んだフィルターを引き継ぎます。

Slackのアプリ一覧からこのアプリを開き、**ホーム**タブで「更新したチケット」「今週期限のチケット」「担当しているチケット」「報告したチケット」の順に表示します。各一覧だけへの切り替えもできます。各区分は最大10件で、11件以上は `10+` と表示します。複数の条件に該当するチケットは各区分に表示します。

Redmineの標準 `IssueQuery` を使い、未完了・有効なプロジェクト・本人の閲覧権限を条件にします。「更新した」は自分の閲覧可能な更新履歴が一度でもあるチケットで、更新日時が新しい順です。「今週期限」は本人または所属グループが担当する今週全体のチケットで、プロジェクト順です。今週の過ぎた期日も含め、週の区切りはRedmineの設定に従います。「担当している」は本人または所属グループが担当するチケットで、優先度の高い順、次に更新日時が新しい順です。「報告した」は自分が作成したチケットで、更新日時が新しい順です。


1. 全体の `slack.app_home: true` を設定し、全体の `slack.bot_token` と `slack.events` のアプリID・チームID・Signing Secretを設定します。
2. Slackアプリの **App Home → Show Tabs → Home Tab** を有効にします。
3. **Event Subscriptions → Subscribe to bot events** に `app_home_opened` を追加します。Request URLは既存の `/slackmine/events` を使います。
4. Redmineユーザーとの対応付けを設定し、RedmineとSidekiqを再起動します。

ホームを開いたとき、表示を切り替えたとき、「更新」を押したときに取得します。チケット変更後も、このホームから保存した場合は一覧を更新します。他の場所での更新は次の取得時に反映します。追加の定期ジョブやDB変更はありません。

閲覧可能で有効なプロジェクトのチケットだけを表示します。共有アプリと異なるアプリ／チームのプロジェクト、`slack.app_home: false` のプロジェクト、共有設定と異なるRedmineユーザーに対応付けられるプロジェクトは除外します。プロジェクトだけに設定した別アプリのホームには対応しません。未対応付けのユーザーには案内だけを表示します。

編集ボタンはチケットへのリンクと、許可された編集フォームを表示します。編集には既存の `work_object_previews`、`work_object_actions`、`work_object_buttons` の設定とRedmineの権限・ワークフローを適用します。編集不可の場合は閲覧用の画面です。プライベートチケットは本人が閲覧可能な場合に一覧へ表示しますが、Slackからの編集は既存の制限に従い無効です。文言は `messages.app_home`（設定例参照）で変更できます。

## スラッシュコマンド

![スラッシュコマンド](docs/images/features/slash-commands.webp)

`slack.slash_command: /slackmine` を設定し、Slackアプリに同名のコマンドを登録します。省略すると無効です。Request URLは `https://redmine.example.com/slackmine/commands`。`commands` スコープを追加してアプリを再インストールしてください。Interactivityは `/slackmine/interactions` を使用します。既存の署名シークレット、app/team ID、Bot Token、ユーザー対応付けも必要です。グローバルの連携設定・ユーザー対応付けを使用し、同じ連携に属するプロジェクトだけを対象にします。

追加テーブル・DBマイグレーションは不要です。フォーム送信・直接変更の再送対策には既存の `Rails.cache` を使用し、処理中は5分、成功済みは24時間記録します。入力エラー時は記録を解除し、修正後に再送できます。例外時は保存結果が不明な可能性があるため、短時間の処理中記録を残します。DB保存とキャッシュ更新は一体ではないため、キャッシュ消失・期限切れ・プロセス内のみのキャッシュ・保存直後の異常終了では重複の可能性が残ります。直接変更はサーバーで生成したリクエスト識別子を使用し、Slackへの応答前に結果を記録するため、配信の再試行では保存済みの結果を再利用します。複数Web・コマンド処理プロセス間の抑止には、`unless_exist` を原子的に扱える共有キャッシュが必要です。プラグインから新しいキャッシュサービスを導入することはありません。

| コマンド | 動作 |
| --- | --- |
| `/slackmine` / `/slackmine help` | 使い方と自分の課題・期限・リマインダー・新規作成ボタン |
| `/slackmine 123` / `/slackmine #123` | 設定済みならWork Objectカード、未設定ならリンク・状態・コメント追加ボタン |
| `/slackmine my` | 自分に直接割り当てられた未完了課題 |
| `/slackmine due` | 自分の期限超過・3日以内が期日の課題 |
| `/slackmine reminders` | 定期リマインダーの設定で、自分の期日一覧を今すぐ取得 |
| `/slackmine search キーワード` | 題名の部分一致検索（大文字小文字を区別しない） |
| `/slackmine new [プロジェクト識別子]` | プロジェクト選択後、トラッカー・題名・説明の作成フォーム |
| `/slackmine comment 123` | コメントフォームを開くボタン |
| `/slackmine status 123 [ステータス名またはID]` | 値を指定すると直接変更、省略すると選択フォームを開くボタン |
| `/slackmine assign 123 [ログイン名・表示名・ID]` | 値を指定すると直接変更、省略すると担当者の選択フォームを開くボタン |

`status`・`assign` は `#123` も受け付けます。値を省略した場合は、返されたボタンから選択フォームを開き、送信して初めて変更を保存します。`/slackmine status 123 終了` や `/slackmine assign 123 alice` のように値を指定すると、キューでコマンドを処理した時点で直接保存します。名前は大文字小文字を区別しない完全一致で、許可された候補を1件に特定できる必要があります。空白を含む名前も引用符なしで指定できます。名前が重複する場合はIDを使ってください。担当者は `me`（自分）、`none`・設定した未割当ラベルも指定できます。不明・重複・許可されない値では変更せず、選択フォームを開くボタンを返します。`/slackmine` は設定した `slack.slash_command` に置き換えてください。`slack.work_object_actions: true`、有効なRedmineユーザーへの対応付け、同じ連携に属する公開課題、対象項目の編集権限が必要です。この2つのコマンドにはWork Objectプレビューの有効化は不要です。ステータスは実行者のRedmineワークフローで許可された候補、担当者はRedmineで割当可能なユーザーと「未割当」を表示します。担当者は最大99人、ステータスは最大100件で、フォームを開けない場合はRedmineの課題編集画面を使用してください。保存時にも連携・権限・ワークフロー・割当候補を再確認し、既存の課題行ロック内で更新します。現在と同じ値を選んだ場合は履歴を追加せずフォームを閉じます。Slack側のコマンド追加登録やスコープ追加は不要です。 直接変更の成功時・値が同じ場合は、プレビュー設定済みなら最新のWork Objectカードを返し、既存の表示項目・ボタン設定を使います。プレビュー未設定では文字の確認応答を返します。配信前に結果を記録するため、再送時に変更やカード生成を繰り返しません。

結果は実行した本人だけに表示します。番号指定、または `my`・`due`・`search` の結果が1件の場合、対象プロジェクトの `slack.work_object_previews: true` が有効でコマンドと同じBot Tokenを使用していれば、自動でWork Objectカードを表示します。項目・ボタンは既存のYAML設定に従い、新たな切替設定は不要です。未設定や非公開課題では簡易表示を使います。 本人だけに表示するカードのボタン押下では、Slackが課題URLと参照情報を省略する場合があるため、操作ボタンに課題IDを持たせています。自分のRedmineで課題を特定したうえで、連携・閲覧・編集権限を通常どおり確認します。本人だけに表示するカードからも、権限で許可されたステータス・優先度・担当者・期日・コメントの編集フォームを開けます。このカードは `chat.update` で更新できないため、保存後は番号指定で再取得してください。複数件の課題一覧はリマインダーと同じ色付き添付・件数見出し・箇条書きに統一し、チケットリンク・プロジェクト名・期日までの相対日数を表示します。期日なしでは日数を省略します。並び順は維持し、各行のボタンは表示しません。行の書式は `messages.due_reminders`、見出しは `messages.commands.my`・`.due`・`.search` を使います。コメント操作は `/slackmine 123` または `/slackmine comment 123` から行えます。一覧は最大100件の候補から10件、プロジェクトは最大20件を表示し、現在のチャンネルに対応するプロジェクトを優先します。プロジェクト識別子で絞り込めます。閲覧権限を確認し、保存時にも権限とRedmineの検証を再確認します。必須カスタムフィールドは簡易作成フォームでは入力できないため、フォーム内のRedmineへのリンクから登録してください。コメント追加には `work_object_actions: true` が必要で、既存の公開課題編集ポリシーに従います。保存後は通常のRedmine通知処理が動きます。チャンネルへ共有する操作は追加していません。

`/slackmine reminders` は定期実行と同じ抽出・表示処理を使います。自分が直接担当する未完了課題のうち、閲覧権限、`due_reminders.enabled`、全体・プロジェクト別の `due_reminders.days` を満たすものが対象です。期限超過・今日・近日の一覧を実行した会話で本人だけに返し、0件でも応答します。100件ずつに分割し、現在のapp/teamと本人のSlack対応付けに一致する課題に限定します。全員向けcronの起動やスケジュール変更は行いません。`due` の固定3日・最大10件とは異なり、設定した期間で全件を返します。表示は既存の `messages.due_reminders` と色設定を使用し、ボタン名と0件時の文言は `messages.commands` で変更できます。Slack側のコマンド追加登録・スコープ追加・DBテーブル追加は不要です。

表示文言はexampleの `messages.commands` で変更できます。`messages.commands.help` は複数行のコマンド一覧で、`%{command}` を `slack.slash_command` に置換します。既存YAMLで `help` を上書きしている場合は、その値を更新するか削除すると新しい既定文を利用できます。スラッシュコマンドはスレッド内では使えません。既存のスレッド返信連携を使用してください。一覧はSlackキューで処理し、新規・コメントフォームは表示されたボタンを押して開きます。フォームを開く処理と保存は同期処理のため、Slackの3秒制限内に収まるよう、ユーザー照合とDBの応答時間に注意してください。

## 毎日の期日リマインダー DM

![毎日の期日リマインダー DM](docs/images/features/due-reminders.webp)

Redmine アプリケーションのタイムゾーンに合わせて、タスクを 1 日 1 回実行します。タスクは `slack` キューにジョブを登録し、ワーカーが DM を送ります。

```bash
cd /path/to/slackmine
bundle exec rake slackmine:due_reminders RAILS_ENV=production
```

Redmine の運用環境で使用しているスケジューラーに、このタスクを 1 日 1 回登録してください。同じ日に再実行した場合も、その都度リマインダーが送られます。

cron から実行する場合は、先に Redmine のディレクトリへ移動する小さなスクリプトにコマンドを記述します。

```sh
#!/bin/sh
cd /path/to/slackmine || exit 1
bundle exec rake slackmine:due_reminders days=7 RAILS_ENV=production
```

Redmine 標準のリマインダーコマンドと同じ絞り込みオプションを Rake の環境引数として指定できます。省略した条件では対象を絞り込みません。

| オプション | 内容 |
| --- | --- |
| `days` | 期日の何日前から通知するか。指定するとプロジェクト別設定を含む YAML の `due_reminders.days` より優先します。省略時は YAML の設定を使います（初期値: 3 日）。 |
| `tracker` | トラッカー ID。 |
| `project` | プロジェクトの ID または識別子。 |
| `users` | 担当 Issue を通知する Redmine ユーザー ID のカンマ区切り。 |
| `version` | 対象バージョン名。Redmine と同様に大文字・小文字を区別せず照合します。 |

たとえば、ユーザー 3 と 5 だけに絞る場合、またはすべての条件を組み合わせる場合は次のように実行します。

```bash
bundle exec rake slackmine:due_reminders users=3,5 RAILS_ENV=production
bundle exec rake slackmine:due_reminders days=7 tracker=2 project=example users=3,5 version="1.0" RAILS_ENV=production
```

指定したすべての条件に一致する Issue だけを対象にし、ワーカーも送信前に条件と担当者を再確認します。値が無効な場合や指定したユーザー・トラッカー・プロジェクト・バージョンが存在しない場合は、ジョブを登録する前に停止します。同じ日に既に通知した Issue も、実行のたびに再送されます。

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

DM の文言は YAML の `messages.due_reminders` 以下で変更できます。[設定例](config/slackmine.yml.example)にすべてのキーとプレースホルダーを掲載しています。たとえば、他のグループを変更せずに見出しと期限超過グループのラベルを変更できます。

```yaml
messages:
  due_reminders:
    title: '📋 *Due reminders: %{count}%{suffix}*'
    overdue_label: '🚨 Overdue'
```

同じキーを `projects.<identifier>.messages.due_reminders` 以下でプロジェクトごとに上書きできます。

## 個人ごとの通知メール設定

![個人ごとの通知メール設定](docs/images/features/email-preference.webp)

**個人設定 → メール通知**の「自分自身による変更の通知は不要」の下で、「Slackで通知する内容のメールを停止」を有効にできます（初期値OFF）。既存のRedmineユーザー設定に保存するため、DBマイグレーションは不要です。

対象はIssue作成・変更・コメント、Wiki作成・更新、News作成・コメントです。メールに含まれる閲覧可能な変更すべてのSlackイベントが有効で、そのプロジェクトのBot Tokenと通知先チャンネルが決まり、対応する本人のSlackアカウントが通知先に参加している場合に停止します。`users`でのログイン名／メールアドレスの明示的な対応付けを優先します。対応付けがなければ、`slack.auto_map_users_by_name: true`による一意の名前マッチングを使い、その都度取得したSlackプロフィールのメールアドレスが本人のRedmineの主メールアドレスと一致することも確認します（大文字・小文字は区別しません）。不正な明示的対応付けがある場合は自動マッチングに切り替えません。通知先は既存のプロジェクト・親プロジェクト・デフォルトの探索を使います。非公開Issue・非公開コメント、対象外の通知、アカウント・セキュリティ関連メールは通常どおりです。

参加確認は`conversations.members`で同期的に行い、参加済みという結果はキャッシュしません。公開チャンネルは`channels:read`、非公開チャンネルは`groups:read`が必要です。名前の自動マッチングには`users:read`と`users:read.email`も必要です。メールアドレスの欠落・不一致、無効なアカウント・ボット・別ワークスペースのアカウント、曖昧な名前、照合失敗時はメールを残します。本人確認はメールごとに行い、プロフィールのメールアドレスはキャッシュしません。スコープ追加後はアプリを再インストールしてください。設定・対応付けの不足、未参加、APIエラー、不正な応答、ページ取得を完了できない場合はメールを残します。取得は1ページ200人、最大10ページで、各リクエストの接続タイムアウトは2秒、読み取りタイムアウトは3秒です。

確認するのは通知設定と参加状況であり、**Slackへの配信成功ではありません**。配信結果を調整するジョブは追加しません。後からSlackへの投稿が失敗しても、停止したメールを代わりに送る処理はありません。Redmineの既存のメール通知選択は変更せず、チェックを外すとその選択に従った通知に戻ります。

## 配信と運用

`SlackmineNotificationJob` は Redmine のイベント後、ActiveJob の `slack` キューに登録されます。Sidekiq を使う場合は、たとえば次のようにキューを設定します。

```yaml
:queues:
  - default
  - mailers
  - slack
```

Slack API の失敗はログに記録され、Sidekiq が再試行します。Redmine の操作はロールバックされません。通知の投稿に成功した後、一時的な画像プレビューの削除に失敗した場合は、重複投稿を避けるため、エラーを記録するだけでジョブを再試行しません。通知が届かない場合は、`SlackmineNotificationJob` と `Slackmine` のログを確認してください。

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

## Redmine本文内のSlackリンクカード

![Redmine本文内のSlackリンクカード](docs/images/features/slack-link-cards.webp)

チケットの説明・コメントに `https://example.slack.com/archives/C123/p1791115675755579` 形式のURLを貼って新規作成・編集すると、Slack本文を取得し、**既存の説明・コメント欄に引用を追記して保存**します。DBマイグレーション・専用テーブル・索引・バックグラウンドジョブは追加しません。引用本文と名前解決済みのメンションは検索可能な文字として保存し、カードの情報は区切り付きのブロックに保持します。元のURL・本文は維持します。引用は保存時点の内容で、Slack側の編集・削除では変わりません。同じ投稿への複数URL（クエリ違いを含む）や再保存でも引用を重複追加しません。コードブロック・インラインコードはRedmineのMarkdown・Textile整形結果に従って除外します。取得できない場合は元の本文のまま保存します。

保存済みカードは元のURLの位置に表示し、カード内の「Slack ↗」から投稿を開けます。コメントの編集直後（Ajax更新）とページの再読み込み後で同じ表示になり、複数のリンクの順序や間に書いた文章を保ちます。カード前後の余分な改行と引用移動後の空段落は取り除き、本文中の通常の改行は維持します。元のURLが削除された場合は、保存済み引用の位置で表示します。保存済みの引用はRuby側でカードにし、閲覧時のJavaScriptやSlack API呼び出しは不要です。引用本文はSlack書式として安全に整形し、Redmineマクロや生HTMLとして実行しません。テキストの通知メール・Slack通知には保存用マーカーを出さず、読める引用を表示します。既存の未取り込みリンクは説明・コメントを変更して保存するまで従来のライブプレビューを維持し、一括で既存レコードを変更しません。保存済みの引用をコピーした場合は、その時点の内容を維持します。

左側の線の色は次のYAMLで指定します。`projects.<識別子>.slack.link_cards` でプロジェクト別に上書きできます。

```yaml
slack:
  link_cards:
    color: '#6D5DFB'
```

6桁の16進カラーのみ受け付け、省略・不正な値では `#6D5DFB` を使います。返信カードには「スレッドへの返信」、取得できた親投稿の短いプレビュー、親投稿へのリンクを表示します。親投稿には返信件数を表示します。リンクの `thread_ts` と投稿のメタデータから返信を判定し、選択した投稿と親投稿だけを取得します。スレッド全体は取り込みません。ユーザー・チャンネルへのメンションは名前を解決し、失敗時は元のラベルやIDを残します。Botのプロフィールがない場合は `bots.info` を試します。

閲覧はRedmineのチケット権限に従い、非公開コメントはそのコメントを読めるユーザーに限定します。閲覧者自身のSlackアカウント紐付け・チャンネル参加は要求しません。**リンクを保存すると、そのチケットの閲覧者にSlack本文（返信の場合は親投稿のプレビューを含む）を共有し、Redmineの本文欄に保存します。** Redmineアプリが対象会話に参加しており、履歴取得用の `channels:history` / `groups:history`（DMは `im:history` / `mpim:history`）と会話情報用の `channels:read` / `groups:read`（DMは `im:read` / `mpim:read`）を持つ必要があります。投稿者・ユーザーメンション・Botのプロフィールには `users:read` を使います。スコープ追加後はアプリを再インストールしてください。プロジェクトのBot Tokenで認証されたワークスペースとリンクのホストを照合し、別ワークスペースのリンクは取得しません。

本文はSlackの `mrkdwn`（太字・斜体・取り消し線・リンク・引用・コード）と基本的なMarkdownの見出し・リスト・太字・リンクを整形します。標準絵文字の名前はUnicodeに変換し、独自絵文字は `:名前:` のまま残します。生HTMLは実行せず文字として表示し、リンク先はHTTP・HTTPS・mailtoに限定します。返信は履歴で取得できない場合 `conversations.replies` を試しますが、APIの制約や失敗で取得できない場合はリンク表示になります。添付ファイルは取り込みません。

1回の保存で最大20件のリンクを候補にし、API呼び出し開始には5秒の予算と短い通信タイムアウトを設けています。制限を超えたリンクは通常表示のままです。同一取り込み中のみBot Token別にAPI結果を再利用します。既存のライブプレビューにも同じ取得制限があります。引用は元の本文欄に保存し、共有HTMLキャッシュは使いません。保存された本文の閲覧・検索結果には、通常のチケット・非公開コメント権限が適用されます。**保存した引用はRedmineの既存の説明・コメント検索で検索可能です。**「タイトルのみ」の検索では本文は対象外なので解除してください。専用の検索索引は不要です。未取り込みの古いリンクは、取り込むまでSlack本文の言葉では検索できません。引用は本文の編集で変更・削除でき、元のURLだけを消しても保存済み引用は残ります。保存した本文の変更には、通常のRedmine通知・変更履歴が適用されます。

## プライバシーと開発

チャンネル通知では、非公開 Issue と非公開 Journal のコメントを除外します。毎日の DM には、担当者が Redmine で閲覧できる非公開 Issue を含められます。非公開 Issue や非公開コメントの画像はアップロードしません。実際の `slackmine.yml` をコミットしたり、Bot Token をログ・設定例・サポート依頼に載せたりしないでください。Token が漏れた場合は更新してください。

ローカルのテストスイートは次のコマンドで実行できます。

```bash
ruby -Itest test/image_notification_test.rb
ruby -Itest test/slack_events_controller_test.rb
ruby -Itest test/slash_commands_cache_test.rb
ruby -Itest test/slash_commands_edit_test.rb
ruby -Itest test/app_home_test.rb
ruby -Itest test/thread_images_test.rb
```

テストはスタブを使って通知の整形と配信ロジックを確認します。追加の `ruby -Itest test/thread_comments_persistence_test.rb` は ActiveRecord と sqlite3 が利用できる環境で実行し、メモリ内のテスト用チケット・コメントテーブルで保存、重複抑制、権限拒否、通知ループ抑制を確認します。本番DBやRedisへ接続せず、Slackへの投稿や稼働中のRedmine環境も検証しません。
