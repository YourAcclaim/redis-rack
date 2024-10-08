require 'rack/session/abstract/id'
require 'redis-store'
require 'thread'
require 'redis/rack/connection'

module Rack
  module Session
    class Redis < Abstract::PersistedSecure
      attr_reader :mutex

      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge(
        :redis_server => 'redis://127.0.0.1:6379/0/rack:session'
      )

      def initialize(app, options = {})
        super

        @mutex = Mutex.new
        @conn = ::Redis::Rack::Connection.new(@default_options)
      end

      def generate_unique_sid(session)
        return generate_sid if session.empty?
        loop do
          sid = generate_sid
          first = with do |c|
            [*c.setnx(sid.private_id, session, @default_options.to_hash)].first
          end
          break sid if [1, true].include?(first)
        end
      end

      def find_session(req, sid)
        if req.session.options[:skip]
          [generate_sid, {}]
        else
          with_lock(req, [nil, {}]) do
            unless sid and session = get_session_with_fallback(sid)
              session = {}
              sid = generate_unique_sid(session)
            end
            [sid, session]
          end
        end
      end

      def write_session(req, sid, new_session, options = {})
        with_lock(req, false) do
          with do |c|
            if prevent_write_after_delete?
              c.watch(sid.private_id) do
                existing_value = c.get(sid.private_id)
                if existing_value != session_tombstone
                  c.multi do |multi|
                    multi.set(sid.private_id, Marshal.dump(wrap_session(new_session)))
                  end
                else
                  c.unwatch
                end
              end
            else
              c.set(sid.private_id, new_session, options.to_hash)
            end
          end
          sid
        end
      end

      def delete_session(req, sid, options)
        with_lock(req) do
          with do |c|
            if prevent_write_after_delete?
              c.del(sid.public_id)
              c.set(sid.private_id, session_tombstone, px: tombstone_expire)
            else
              c.del(sid.public_id)
              c.del(sid.private_id)
            end
          end
          generate_sid unless options[:drop]
        end
      end

      def session_tombstone
        {"__deleted" => true}
      end

      def wrap_session(session)
        {"__deleted" => false, "session" => session}
      end

      def unwrap_session(session)
        if session.is_a?(Hash) && session.key?("__deleted")
          session["session"]
        else
          session
        end
      end

      def prevent_write_after_delete?
        @default_options.fetch(:prevent_write_after_delete, false)
      end

      def tombstone_expire
        @default_options.fetch(:tombstone_expire, 60 * 1_000)
      end

      def threadsafe?
        @default_options.fetch(:threadsafe, true)
      end

      def with_lock(req, default = nil)
        @mutex.lock if threadsafe?
        yield
      rescue Errno::ECONNREFUSED
        if $VERBOSE
          warn "#{self} is unable to find Redis server."
          warn $!.inspect
        end
        default
      ensure
        @mutex.unlock if @mutex.locked?
      end

      def with(&block)
        @conn.with(&block)
      end

      private

      def get_session_with_fallback(sid)
        with do |c|
          if prevent_write_after_delete?
            unwrap_session(c.get(sid.private_id))
          else
            c.get(sid.private_id) || c.get(sid.public_id)
          end
        end
      end
    end
  end
end
