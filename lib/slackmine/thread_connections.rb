# frozen_string_literal: true

require 'securerandom'
require 'base64'

module Slackmine
  # Slack is the durable connection store. A signed block_id on our Bot's
  # connection/closure messages binds the state to this exact app/team/thread.
  # No plugin table, DB migration, or preview cache is required.
  module ThreadConnections
    module_function

    CALLBACK = 'slackmine_thread_connect'
    PICK_CALLBACK = 'slackmine_thread_connect_pick'
    SAVE_CALLBACK = 'slackmine_thread_connect_save'
    MARKER_PREFIX = 'slackmine_connection:'
    MAX_HISTORY = 20
    MAX_SCAN = 1000

    def enabled?(project = nil)
      Slackmine.effective_config(project).dig('slack', 'thread_connections') != false
    end

    def receives?(app, team)
      events = Slackmine.effective_config(nil).dig('slack', 'events') || {}
      enabled? && events['app_id'] == app && events['team_id'] == team &&
        WorkObjects.integration_for(app, team) && !Slackmine.bot_token(nil).to_s.empty?
    end

    def handles?(payload)
      (payload['type'] == 'message_action' && payload['callback_id'] == CALLBACK) ||
        (payload['type'] == 'view_submission' && [PICK_CALLBACK, SAVE_CALLBACK].include?(payload.dig('view', 'callback_id')))
    end

    def scope?(issue, app, team)
      issue && issue.project.active? && !issue.is_private? && enabled?(issue.project) &&
        WorkObjects.integration_for(app, team, project: issue.project) &&
        !Slackmine.bot_token(nil).to_s.empty? && Slackmine.bot_token(issue.project) == Slackmine.bot_token(nil)
    end

    def allowed?(issue, viewer, app, team)
      scope?(issue, app, team) && viewer && issue.visible?(viewer) && issue.notes_addable?(viewer)
    end

    def secret(app, team)
      WorkObjects.integration_for(app, team)&.fetch('signing_secret', nil).to_s
    end

    def signature(app, team, channel, ts, data)
      key = secret(app, team)
      raise 'Slack signing secret is required' if key.empty?
      OpenSSL::HMAC.hexdigest('SHA256', key, JSON.generate([app, team, channel, ts, data]))
    end

    def signed_source(app, team, source)
      encoded = Base64.strict_encode64(JSON.generate(source))
      JSON.generate('data' => encoded, 'signature' => signature(app, team, source['channel'], source['ts'], encoded))
    end

    def source_for(app, team, viewer, payload)
      return unless viewer
      metadata = payload.dig('view', 'private_metadata').to_s
      return if metadata.bytesize > 3000
      envelope = JSON.parse(metadata)
      source = JSON.parse(Base64.strict_decode64(envelope.fetch('data')))
      expected = signature(app, team, source['channel'], source['ts'], envelope['data'])
      return unless secure_equal?(expected, envelope['signature']) && source['user_id'] == viewer.id
      source
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      nil
    end

    def secure_equal?(left, right)
      right.is_a?(String) && left.bytesize == right.bytesize &&
        left.bytes.zip(right.bytes).reduce(0) { |n, (a, b)| n | (a ^ b) }.zero?
    end

    def section(text)
      { 'type' => 'section', 'text' => { 'type' => 'plain_text', 'text' => text[0, 3000] } }
    end

    def input(id, label, element, optional: false)
      { 'type' => 'input', 'block_id' => id, 'optional' => optional,
        'label' => { 'type' => 'plain_text', 'text' => label }, 'element' => element.merge('action_id' => id) }
    end

    def modal(blocks, app: nil, team: nil, source: nil, callback: nil, submit: nil)
      view = { 'type' => 'modal', 'title' => { 'type' => 'plain_text', 'text' => 'スレッドをチケットに接続' },
               'close' => { 'type' => 'plain_text', 'text' => '閉じる' }, 'blocks' => blocks }
      if source
        view['private_metadata'] = signed_source(app, team, source)
        raise 'Preview metadata exceeds Slack limit' if view['private_metadata'].bytesize > 3000
      end
      view['callback_id'] = callback if callback
      view['submit'] = { 'type' => 'plain_text', 'text' => submit } if submit
      view
    end

    def state(payload, id)
      payload.dig('view', 'state', 'values', id, id) || {}
    end

    def error(text)
      { 'response_action' => 'errors', 'errors' => { 'issue' => text } }
    end

    def timestamp_now
      time = Time.now.utc
      format('%d.%06d', time.to_i, time.usec)
    end

    def interaction(app, team, payload)
      return {} unless receives?(app, team)
      viewer = WorkObjects.viewer_for(payload.dig('user', 'id'))
      if payload['type'] == 'message_action'
        open_picker(app, team, viewer, payload)
      elsif payload.dig('view', 'callback_id') == PICK_CALLBACK
        pick(app, team, viewer, payload)
      else
        save(app, team, viewer, payload)
      end
    end

    def open_picker(app, team, viewer, payload)
      return {} if payload['trigger_id'].to_s.empty?
      channel = payload.dig('channel', 'id').to_s
      ts = (payload.dig('message', 'thread_ts') || payload.dig('message', 'ts')).to_s
      valid = viewer && channel.match?(/\A[CG][A-Z0-9]+\z/) && ThreadComments.posted_at(ts)
      if valid
        source = { 'channel' => channel, 'ts' => ts, 'slack_user' => payload.dig('user', 'id'),
                   'user_id' => viewer.id, 'nonce' => SecureRandom.hex(16) }
        loading = modal([section('このスレッドの接続設定を確認しています…')])
        result = Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => loading }, Slackmine.bot_token(nil))
        SlackmineThreadConnectionJob.set(wait: 1).perform_later(app, team, source, result.dig('view', 'id'), 'picker')
      else
        Slackmine.slack_api('views.open', { 'trigger_id' => payload['trigger_id'], 'view' => modal([section('ユーザーの対応付けとチャンネルを確認してください。DMには対応していません。')]) }, Slackmine.bot_token(nil))
      end
      {}
    end

    def verify_channel!(channel, user, token)
      info = Slackmine.slack_api('conversations.info', { 'channel' => channel }, token, form: true)['channel']
      raise 'Bot is not a channel member' unless info.is_a?(Hash) && info['id'] == channel && info['is_member'] == true && !info['is_im'] && !info['is_mpim']
      cursor = nil
      20.times do
        body = { 'channel' => channel, 'limit' => 200 }
        body['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.members', body, token, form: true)
        return info if Array(response['members']).include?(user)
        cursor = response.dig('response_metadata', 'next_cursor').to_s
        break if cursor.empty?
      end
      raise 'Initiator is not a verified channel member'
    end

    def history(source, token = Slackmine.bot_token(nil))
      messages = []
      cursor = nil
      10.times do
        body = { 'channel' => source['channel'], 'ts' => source['ts'], 'limit' => 100 }
        body['cursor'] = cursor if cursor
        response = Slackmine.slack_api('conversations.replies', body, token, form: true)
        messages.concat(Array(response['messages']))
        raise 'Thread exceeds 1000 messages' if messages.size > MAX_SCAN
        cursor = response.dig('response_metadata', 'next_cursor').to_s
        if cursor.empty?
          raise 'Incomplete Slack thread history' if response['has_more']
          return messages.select { |m| m.is_a?(Hash) && ThreadComments.posted_at(m['ts']) }
                         .uniq { |m| m['ts'] }.sort_by { |m| ThreadComments.posted_at(m['ts']) }
        end
      end
      raise 'Incomplete Slack thread history'
    end

    def marker(app, team, source, message)
      return unless message['bot_id'] && (message['app_id'] || message.dig('bot_profile', 'app_id')) == app
      block = Array(message['blocks']).find { |b| b.is_a?(Hash) && b['block_id'].to_s.start_with?(MARKER_PREFIX) }
      return unless block
      encoded, digest = block['block_id'].delete_prefix(MARKER_PREFIX).split(':', 2)
      return unless encoded && secure_equal?(signature(app, team, source['channel'], source['ts'], encoded), digest)
      data = JSON.parse(Base64.strict_decode64(encoded))
      return unless data.is_a?(Array) && data.size == 4 && data[0].is_a?(Integer) && data[0] > 0 &&
                    ThreadComments.posted_at(data[1]) && data[2].to_s.match?(/\A[0-9a-f]{32}\z/) && [true, false].include?(data[3])
      { 'issue_id' => data[0], 'cutoff' => data[1], 'nonce' => data[2], 'active' => data[3], 'marker_ts' => message['ts'] }
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def connection(app, team, source, messages)
      current = nil
      messages.each do |message|
        item = marker(app, team, source, message)
        next unless item
        # First connection wins until a closure for that exact nonce. A late
        # retry or stale closure cannot replace/disconnect a later connection.
        if item['active']
          current = item unless current && current['active']
        elsif current && current['active'] && current['nonce'] == item['nonce']
          current = item
        end
      end
      current
    end

    def human_message?(message)
      message.is_a?(Hash) && !message['bot_id'] && !message['app_id'] &&
        [nil, '', 'thread_broadcast', 'file_share'].include?(message['subtype']) &&
        message['user'].to_s.match?(/\A[UW][A-Z0-9]+\z/) &&
        (!MessageShortcuts.message_text(message).strip.empty? || Array(message['files']).any?)
    end

    def snapshot(message)
      { 'type' => 'message', 'ts' => message['ts'], 'user' => message['user'],
        'text' => MessageShortcuts.message_text(message),
        'files' => Array(message['files']).map { |f| f.is_a?(Hash) ? f.slice('id') : {} } }
    end

    def fingerprint(message)
      # Shorten only the identity digest, never the quoted body.
      Digest::SHA256.hexdigest(JSON.generate(snapshot(message)))[0, 32]
    end

    def prepare_picker(app, team, source, view_id)
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Unknown user' unless viewer && viewer.id == source['user_id'] && enabled?
      verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      current = connection(app, team, source, history(source))
      if current && current['active']
        issue = Issue.find_by(id: current['issue_id'])
        raise 'Permission denied' unless allowed?(issue, viewer, app, team)
        source = source.merge(current).merge('disconnect' => true)
        view = modal([section("このスレッドは ##{issue.id} に接続されています。解除しても保存済みコメントは残ります。"),
          input('issue', '接続先', { 'type' => 'plain_text_input', 'initial_value' => issue.id.to_s })],
          app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: '接続を解除')
      else
        option = { 'text' => { 'type' => 'plain_text', 'text' => 'これまでの会話も保存する' }, 'value' => 'history' }
        view = modal([section('接続するチケット番号を入力してください。確認画面で過去の発言を選べます。'),
          input('issue', 'チケット番号', { 'type' => 'plain_text_input' }),
          input('history', '過去の会話', { 'type' => 'checkboxes', 'options' => [option], 'initial_options' => [option] }, optional: true)],
          app: app, team: team, source: source, callback: PICK_CALLBACK, submit: '内容を確認')
      end
      update_view(view_id, view)
    rescue StandardError => e
      preview_error(view_id, e)
    end

    def pick(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return error('確認情報が無効です。メニューからやり直してください。') unless source
      id = state(payload, 'issue')['value'].to_s.strip.sub(/\A#/, '')
      issue = Issue.find_by(id: id) if id.match?(/\A[1-9]\d*\z/)
      return error('チケットが見つからないか、接続する権限がありません。') unless allowed?(issue, viewer, app, team)
      source = source.merge('issue_id' => issue.id, 'history' => Array(state(payload, 'history')['selected_options']).any? { |o| o['value'] == 'history' }, 'cutoff' => timestamp_now)
      SlackmineThreadConnectionJob.set(wait: 1).perform_later(app, team, source, payload.dig('view', 'id'), 'preview')
      { 'response_action' => 'update', 'view' => modal([section('チケットとスレッドの内容を確認しています…')]) }
    end

    def prepare_preview(app, team, source, view_id)
      issue = Issue.find_by(id: source['issue_id'])
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Permission denied' unless viewer && viewer.id == source['user_id'] && allowed?(issue, viewer, app, team)
      channel_info = verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      messages = source['history'] ? history(source) : []
      mention_cache = {}
      messages.select! do |m|
        human_message?(m) && ThreadComments.posted_at(m['ts']) <= ThreadComments.posted_at(source['cutoff']) &&
          !ThreadComments.addressed_to_bot?(m, issue.project, cache: mention_cache)
      end
      raise 'Past conversation exceeds 20 human posts' if messages.size > MAX_HISTORY
      cache = {}
      call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
      blocks = [section("##{issue.id} #{issue.subject}\n過去分はあなたの名義の1件の引用コメントにまとめます。保存する発言を選んでください。確認中に届いた返信も権限に応じて保存します。"),
                input('issue', '接続先チケット番号', { 'type' => 'plain_text_input', 'initial_value' => issue.id.to_s })]
      source = source.merge('posts' => messages.map { |m| [m['ts'], fingerprint(m)] }, 'ready' => true)
      messages.each_with_index do |m, index|
        card = LinkCards.message_card(m, call)
        text = MessageShortcuts.message_text(m)
        raise 'A post exceeds 10000 characters' if text.length > 10_000
        preview = "#{card['author']} · #{card['timestamp']}\n#{text}\n添付: #{Array(m['files']).size}件"
        preview.scan(/.{1,2900}/m).each { |part| blocks << section(part) }
        option = { 'text' => { 'type' => 'plain_text', 'text' => 'この発言を保存する' }, 'value' => index.to_s }
        blocks << input("post_#{index}", '取り込み', { 'type' => 'checkboxes', 'options' => [option], 'initial_options' => [option] }, optional: true)
      end
      raise 'Preview exceeds Slack block limit' if blocks.size > 100
      update_view(view_id, modal(blocks, app: app, team: team, source: source, callback: SAVE_CALLBACK, submit: '接続する'))
    rescue StandardError => e
      preview_error(view_id, e)
    end

    def update_view(view_id, view)
      Slackmine.slack_api('views.update', { 'view_id' => view_id, 'view' => view }, Slackmine.bot_token(nil))
    end

    def preview_error(view_id, error)
      Rails.logger&.warn("Slackmine: connection preview failed: #{error.class}")
      update_view(view_id, modal([section('確認できませんでした。権限・Botの参加・スコープを確認してください。過去分は人の発言20件、スレッド全体は1000件までです。メニューからやり直せます。')]))
    end

    def save(app, team, viewer, payload)
      source = source_for(app, team, viewer, payload)
      return error('確認情報が無効です。メニューからやり直してください。') unless source
      issue = Issue.find_by(id: source['issue_id'])
      return error('操作する権限がありません。') unless allowed?(issue, viewer, app, team)
      return error('接続先を変える場合はメニューからやり直してください。') unless state(payload, 'issue')['value'].to_s == issue.id.to_s
      return error('確認が完了していません。') unless source['disconnect'] || source['ready']
      selected = Array(source['posts']).each_with_index.select do |_, index|
        Array(state(payload, "post_#{index}")['selected_options']).any? { |o| o['value'] == index.to_s }
      end.map(&:first)
      SlackmineThreadConnectionJob.perform_later(app, team, source.merge('posts' => selected))
      {}
    end

    def post_marker(app, team, source, active:)
      issue = Issue.find_by(id: source['issue_id'])
      raise 'Invalid integration' unless scope?(issue, app, team)
      encoded = Base64.strict_encode64(JSON.generate([issue.id, source['cutoff'], source['nonce'], active]))
      block_id = MARKER_PREFIX + encoded + ':' + signature(app, team, source['channel'], source['ts'], encoded)
      raise 'Marker exceeds Slack limit' if block_id.length > 255
      text = "<#{Formatter.url("/issues/#{issue.id}")}|##{issue.id}> " +
             (active ? 'このスレッドを接続しました。以後の返信・添付を保存します。' : '接続を解除しました。保存済みコメントは残ります。')
      Slackmine.slack_api('chat.postMessage', { 'channel' => source['channel'], 'thread_ts' => source['ts'], 'text' => text,
        'blocks' => [{ 'type' => 'section', 'block_id' => block_id, 'text' => { 'type' => 'mrkdwn', 'text' => text } }],
        'unfurl_links' => false, 'unfurl_media' => false }, Slackmine.bot_token(nil))
    end

    def finish(app, team, source)
      issue = Issue.find_by(id: source['issue_id'])
      viewer = WorkObjects.viewer_for(source['slack_user'])
      raise 'Permission denied' unless viewer && viewer.id == source['user_id'] && allowed?(issue, viewer, app, team)
      channel_info = verify_channel!(source['channel'], source['slack_user'], Slackmine.bot_token(nil))
      messages = history(source)
      current = connection(app, team, source, messages)
      if source['disconnect']
        return unless current && current['active'] && current['nonce'] == source['nonce']
        post_marker(app, team, source, active: false)
        return
      end
      # A cancelled/closed request is never resurrected by a delayed retry,
      # including after a different connection has also been closed.
      closed = messages.any? do |m|
        item = marker(app, team, source, m)
        item && !item['active'] && item['nonce'] == source['nonce']
      end
      return if closed
      if current && current['active'] && current['nonce'] != source['nonce']
        return failure_notice(source, '既に別の接続が設定されています。メニューから確認してください。')
      end
      selected = Array(source['posts']).map do |ts, digest|
        message = messages.find { |m| m['ts'] == ts }
        raise 'The selected conversation changed; preview again' unless message && human_message?(message) && fingerprint(message) == digest
        message
      end
      raise 'Selected text exceeds 10000 characters' if selected.map { |m| MessageShortcuts.message_text(m) }.join("\n\n").length > 10_000
      unless current && current['active']
        posted = post_marker(app, team, source, active: true)
        messages = history(source)
        current = connection(app, team, source, messages)
        unless current && current['active'] && current['nonce'] == source['nonce']
          # Only remove the losing confirmation created by this job.
          Slackmine.slack_api('chat.delete', { 'channel' => source['channel'], 'ts' => posted['ts'] }, Slackmine.bot_token(nil)) if ThreadComments.posted_at(posted['ts'])
          return failure_notice(source, '別の接続が先に設定されました。メニューから確認してください。')
        end
      end
      cache = {}
      call = lambda { |method, body| cache[[method, body]] ||= Slackmine.slack_api(method, body, Slackmine.bot_token(nil), form: true) }
      entries = selected.map do |m|
        card = LinkCards.message_card(m, call).merge('channel' => channel_info['name'] || source['channel'],
          'text' => MessageShortcuts.message_text(m), 'thread_connection_nonce' => source['nonce'])
        card['text'] = '[添付ファイル]' if card['text'].empty?
        { 'event' => snapshot(m).merge('channel' => source['channel'], 'thread_ts' => source['ts']), 'card' => card }
      end
      Slackmine.with_project(issue.project) do
        if entries.any?
          result = ThreadComments.persist_reply(issue, entries.first['event'], team, events: entries.map { |e| e['event'] },
            connected: true, import_viewer: viewer, history_cards: entries, import_timestamp: ThreadComments.posted_at(source['cutoff']))
          raise "History import failed: #{result}" unless [:saved, :duplicate].include?(result)
        end
        # Events accepted while the modal was open can precede the connection
        # marker. Replay those replies; existing Journal identity deduplicates them.
        messages.each do |m|
          next unless human_message?(m) && ThreadComments.posted_at(m['ts']) > ThreadComments.posted_at(source['cutoff'])
          process_reply(current, app, team, snapshot(m).merge('channel' => source['channel'], 'thread_ts' => source['ts']))
        end
      end
    rescue StandardError => e
      Rails.logger&.error("Slackmine: connection operation failed: #{e.class}")
      failure_notice(source, '処理を完了できませんでした。確認後に会話が変わった場合は、接続を解除してから再確認してください。管理者はSlackキューの失敗ジョブも確認できます。')
      raise
    end

    def process_reply(current, app, team, event)
      return :ignored unless current['active'] && enabled?
      return :ignored unless ThreadComments.posted_at(event['ts']) > ThreadComments.posted_at(current['cutoff'])
      issue = Issue.find_by(id: current['issue_id'])
      return :ignored unless scope?(issue, app, team)
      Slackmine.with_project(issue.project) do
        return :ignored if ThreadComments.addressed_to_bot?(event, issue.project)
        result = ThreadComments.persist_reply(issue, event, team, connected: true)
        ThreadComments.feedback(issue, event, result) unless result == :duplicate
        result
      end
    end

    def failure_notice(source, text)
      Slackmine.slack_api('chat.postEphemeral', { 'channel' => source['channel'], 'user' => source['slack_user'], 'text' => text }, Slackmine.bot_token(nil))
    rescue StandardError => e
      Rails.logger&.warn("Slackmine: connection feedback failed: #{e.class}")
    end
  end
end
