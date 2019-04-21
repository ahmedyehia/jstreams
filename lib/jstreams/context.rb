# frozen_string_literal: true

require 'json'
require 'connection_pool'

require_relative 'serializers/json'
require_relative 'publisher'
require_relative 'subscriber'
require_relative 'tagged_logging'

module Jstreams
  ##
  # A collection of jstreams subscribers, their associated threads, and an interface for
  # publishing messages.
  class Context
    attr_reader :redis_pool, :serializer, :logger

    def initialize(
      redis_url: nil,
      serializer: Serializers::JSON.new,
      logger: Logger.new(ENV['JSTREAMS_VERBOSE'] ? STDOUT : File::NULL)
    )
      # TODO: configurable/smart default pool size
      @redis_pool =
        ::ConnectionPool.new(size: 10, timeout: 5) { Redis.new(url: redis_url) }
      @serializer = serializer
      @logger = TaggedLogging.new(logger)
      @publisher =
        Publisher.new(
          redis_pool: @redis_pool, serializer: serializer, logger: @logger
        )
      @subscribers = []
    end

    def publish(stream, message)
      @publisher.publish(stream, message)
    end

    def subscribe(name, streams, key: name, **kwargs, &block)
      subscriber =
        Subscriber.new(
          redis_pool: @redis_pool,
          logger: @logger,
          serializer: @serializer,
          name: name,
          key: key,
          streams: Array(streams),
          handler: block,
          **kwargs
        )
      @subscribers << subscriber
      subscriber
    end

    def unsubscribe(subscriber)
      @subscribers.delete(subscriber)
    end

    def run(wait: true)
      trap('INT') { shutdown }
      Thread.abort_on_exception = true
      @subscriber_threads =
        @subscribers.map { |subscriber| Thread.new { subscriber.run } }
      wait_for_shutdown if wait
    end

    def wait_for_shutdown
      @subscriber_threads.each(&:join)
    end

    def shutdown
      @subscribers.each(&:stop)
    end
  end
end
