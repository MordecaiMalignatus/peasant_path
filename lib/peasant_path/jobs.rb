require "logger"

module PeasantPath
  class Jobs
    def initialize(logger = Logger.new($stdout))
      @logger = logger
      @lock = Mutex.new
      @busy = false
    end

    def busy?
      @lock.synchronize { @busy }
    end

    def run
      @lock.synchronize do
        return false if @busy
        @busy = true
      end

      Thread.new do
        begin
          yield
        rescue => e
          @logger.error("background job failed: #{e.class}: #{e.message}")
        ensure
          @lock.synchronize { @busy = false }
        end
      end

      true
    end
  end
end
