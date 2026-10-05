# frozen_string_literal: true
require 'tempfile'

module Slackmine
  module ThreadImages
    class ImportError < StandardError; end
    MAX_FILES = 10
    MAX_BYTES = 10 * 1024 * 1024
    MAX_TOTAL_BYTES = 50 * 1024 * 1024
    TYPES = { 'image/png' => '.png', 'image/jpeg' => '.jpg',
              'image/gif' => '.gif', 'image/webp' => '.webp' }.freeze
    module_function

    def download(event, token)
      references = Array(event['files'])
      return [] if references.empty?
      raise ImportError, 'Too many images' if references.length > MAX_FILES
      ids = references.map { |file| file.is_a?(Hash) && file['id'] }
      raise ImportError, 'Invalid file references' unless ids.all? { |id| id.is_a?(String) && id.match?(/\AF[A-Z0-9]+\z/) }
      uploads = []
      total = 0
      limit = [MAX_BYTES, Setting.attachment_max_size.to_i * 1024].min
      ids.uniq.each do |id|
        file = Slackmine.slack_api('files.info', { 'file' => id }, token, form: true)['file']
        unless file.is_a?(Hash) && file['id'] == id && TYPES.key?(file['mimetype']) &&
               !file['is_external'] && file['size'].is_a?(Integer) && file['size'].between?(1, limit)
          raise ImportError, 'Unsupported image or size'
        end
        raise ImportError, 'Images exceed total size limit' if total + file['size'] > MAX_TOTAL_BYTES
        upload = fetch(file['url_private_download'] || file['url_private'], token, limit)
        uploads << upload
        raise ImportError, 'Incomplete image download' unless upload.size == file['size']
        total += upload.size
        raise ImportError, 'Images exceed total size limit' if total > MAX_TOTAL_BYTES
        raise ImportError, 'Image content does not match its type' unless image_type(upload) == file['mimetype']
        # Prefix with the Slack file ID to avoid collisions with existing files.
        name = file['name'].to_s.split(/[\\\/]/).last.to_s.gsub(/[^A-Za-z0-9_@.-]/, '_')[0, 120]
        name = 'image' if name.empty?
        filename = "#{id}-#{File.basename(name, File.extname(name))}#{TYPES.fetch(file['mimetype'])}"
        mime = file['mimetype']
        upload.define_singleton_method(:original_filename) { filename }
        upload.define_singleton_method(:content_type) { mime }
      end
      uploads
    rescue Slackmine::SlackApiError => error
      uploads.each(&:close!) if uploads
      raise ImportError, error.code if %w[missing_scope file_not_found access_denied].include?(error.code)
      raise
    rescue StandardError
      uploads.each(&:close!) if uploads
      raise
    end

    def fetch(url, token, limit)
      uri = URI.parse(url.to_s)
      # Never forward the bot token to arbitrary hosts or follow redirects.
      unless uri.scheme == 'https' && uri.host == 'files.slack.com' && uri.port == 443 &&
             !uri.userinfo && uri.path.start_with?('/files-pri/')
        raise ImportError, 'Invalid Slack download URL'
      end
      upload = Tempfile.new('slackmine-image')
      upload.binmode
      request = Net::HTTP::Get.new(uri.request_uri)
      request['Authorization'] = "Bearer #{token}"
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        http.request(request) do |response|
          raise IOError, 'Temporary image download failure' if response.code.to_i == 429 || response.code.to_i >= 500
          raise ImportError, 'Image download failed' unless response.is_a?(Net::HTTPSuccess)
          raise ImportError, 'Image too large' if response['Content-Length'].to_i > limit
          response.read_body do |chunk|
            raise ImportError, 'Image too large' if upload.size + chunk.bytesize > limit
            upload.write(chunk)
          end
        end
      end
      raise ImportError, 'Empty image' if upload.size.zero?
      upload.rewind
      upload
    rescue URI::InvalidURIError
      raise ImportError, 'Invalid Slack download URL'
    rescue StandardError
      upload.close! if upload
      raise
    end

    def image_type(file)
      bytes = file.read(12).to_s.b
      file.rewind
      return 'image/png' if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
      return 'image/jpeg' if bytes.start_with?("\xff\xd8\xff".b)
      return 'image/gif' if bytes.start_with?('GIF87a', 'GIF89a')
      return 'image/webp' if bytes.start_with?('RIFF') && bytes[8, 4] == 'WEBP'
      nil
    end
  end
end
