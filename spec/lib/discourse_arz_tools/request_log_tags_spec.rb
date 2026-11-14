# frozen_string_literal: true

require "stringio"

RSpec.describe DiscourseArzTools::RequestLogTags do
  let(:output) { StringIO.new }
  let(:logger) { ActiveSupport::TaggedLogging.new(Logger.new(output)) }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def request_env(id)
    Rack::MockRequest.env_for("/diagnostics", "action_dispatch.request_id" => id)
  end

  it "tags existing request logs and preserves other configured tags" do
    app = lambda do |_env|
      Rails.logger.info("inside request")
      [200, {}, ["ok"]]
    end
    middleware = Rails::Rack::Logger.new(app, ["existing"])

    response = middleware.call(request_env("first-request"))
    response[2].close
    Rails.logger.info("outside request")

    request_lines = output.string.lines.reject { |line| line.include?("outside request") }
    expect(request_lines.size).to eq(2)
    expect(request_lines.any? { |line| line.include?("Started GET") }).to eq(true)
    request_lines.each do |line|
      expect(line).to include("[existing]", "[pid=#{Process.pid}]", "[request_id=first-request]")
    end
    expect(output.string.lines.last).not_to include("[request_id=", "[pid=", "[existing]")
  end

  it "does not leak request tags after an exception or into the next request" do
    failing_app = ->(_env) { raise "request failed" }
    middleware = Rails::Rack::Logger.new(failing_app)

    expect { middleware.call(request_env("failed-request")) }.to raise_error("request failed")
    Rails.logger.info("after exception")
    expect(output.string.lines.last).not_to include("[request_id=", "[pid=")

    middleware = Rails::Rack::Logger.new(->(_env) { [200, {}, ["ok"]] })
    response = middleware.call(request_env("next-request"))
    response[2].close

    next_line = output.string.lines.find { |line| line.include?("[request_id=next-request]") }
    expect(next_line).to include("[pid=#{Process.pid}]")
    expect(next_line).not_to include("failed-request")
  end
end
