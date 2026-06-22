require "peasant_path"

RSpec.describe PeasantPath::Jobs do
  let(:logger) { instance_double(Logger, error: nil) }

  it "serializes jobs" do
    queue = Queue.new
    jobs = described_class.new(logger)

    expect(jobs.run { queue.pop }).to be true
    expect(jobs.run { }).to be false

    queue << true
    sleep 0.01 while jobs.busy?
    expect(jobs.run { }).to be true
  end

  it "releases the busy flag after errors" do
    jobs = described_class.new(logger)

    jobs.run { raise "boom" }
    sleep 0.01 while jobs.busy?

    expect(jobs.busy?).to be false
    expect(logger).to have_received(:error).with(/background job failed: RuntimeError: boom/)
  end
end
