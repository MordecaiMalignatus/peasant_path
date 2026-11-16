require "logger"

module PeasantPath
  # Runs background work one job at a time on a single worker thread, so two
  # background jobs (a pull, a build, the first pull of a new follow) never
  # overlap each other.
  #
  # Two ways in: `run` is for work that is pointless to stack (a second "pull
  # now" behind a running pull) and is refused while anything is running;
  # `enqueue` is for work a user asked for that must not be lost (the first
  # pull of a newly followed story, a rebuild after a rename) and waits its
  # turn instead.
  class Jobs
    def initialize(logger = Logger.new($stdout))
      @logger = logger
      @lock = Mutex.new
      @pending = []
      @busy = false
    end

    # True while a job is running or waiting.
    def busy?
      @lock.synchronize { @busy }
    end

    # Start the block in the background unless a job is already running or
    # waiting. Returns whether it was started.
    def run(&block)
      @lock.synchronize do
        return false if @busy

        @pending << block
        start_worker
      end
      true
    end

    # Run the block in the background after every job already running or
    # waiting. Returns true when it starts right away, false when it has to
    # wait.
    def enqueue(&block)
      @lock.synchronize do
        @pending << block
        return false if @busy

        start_worker
      end
      true
    end

    private

    # Caller holds @lock. The worker drains @pending and clears @busy under
    # the same lock it checks the queue with, so a job added just as the
    # queue empties either gets picked up or starts a new worker.
    def start_worker
      @busy = true
      Thread.new do
        while (job = next_job)
          # Anything a job raises, a LoadError from a missing browser driver
          # included, must not end this loop: the jobs queued behind it would
          # never run and busy? would stay true until the process restarts.
          begin
            job.call
          rescue Exception => e
            @logger.error("background job failed: #{e.class}: #{e.message}")
          end
        end
      end
    end

    def next_job
      @lock.synchronize do
        job = @pending.shift
        @busy = false if job.nil?
        job
      end
    end
  end
end
