require "peasant_path"
require "timeout"

RSpec.describe PeasantPath::Jobs do
  let(:logger) { instance_double(Logger, error: nil) }
  let(:jobs) { described_class.new(logger) }

  # Every wait is bounded so a stuck worker fails the example instead of
  # hanging the suite.
  def wait_seconds = 2

  def wait_until_idle(jobs)
    Timeout.timeout(wait_seconds) { sleep 0.01 while jobs.busy? }
  end

  def pop(queue)
    queue.pop(timeout: wait_seconds) or raise "nothing arrived within #{wait_seconds}s"
  end

  describe "#run" do
    it "serializes jobs" do
      gate = Queue.new

      expect(jobs.run { gate.pop }).to be true
      expect(jobs.run { }).to be false

      gate << true
      wait_until_idle(jobs)
      expect(jobs.run { }).to be true
    end

    it "is refused while an enqueued job is still waiting" do
      gate = Queue.new
      jobs.run { gate.pop }
      jobs.enqueue { }

      expect(jobs.run { }).to be false

      gate << true
      wait_until_idle(jobs)
    end

    it "accepts work again after a job fails" do
      jobs.run { raise "boom" }
      wait_until_idle(jobs)

      expect(jobs.run { }).to be true
      expect(logger).to have_received(:error).with(/background job failed: RuntimeError: boom/)
    end
  end

  describe "#enqueue" do
    it "starts right away when idle" do
      ran = Queue.new

      expect(jobs.enqueue { ran << :done }).to be true
      expect(pop(ran)).to eq :done
    end

    it "runs after the current job instead of being dropped" do
      gate = Queue.new
      order = Queue.new
      jobs.run { gate.pop && order << :first }

      expect(jobs.enqueue { order << :second }).to be false
      expect(jobs.enqueue { order << :third }).to be false
      expect(jobs.busy?).to be true

      gate << true
      wait_until_idle(jobs)
      expect(Array.new(order.size) { order.pop }).to eq %i[first second third]
    end

    it "keeps going after a job fails, even with an error outside StandardError" do
      gate = Queue.new
      ran = Queue.new
      jobs.run { gate.pop && raise(LoadError, "cannot load such file -- playwright") }
      jobs.enqueue { ran << :after }

      gate << true
      expect(pop(ran)).to eq :after
      wait_until_idle(jobs)
      expect(logger).to have_received(:error).with(/LoadError/)
    end
  end
end
