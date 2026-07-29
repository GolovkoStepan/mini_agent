# frozen_string_literal: true

RSpec.describe MiniAgent::ProcessRunner do
  subject(:runner) { described_class.new(timeout: 5) }

  it "возвращает stdout и нулевой код выхода" do
    result = runner.call("echo привет")

    expect(result.stdout.strip).to eq("привет")
    expect(result.exit_code).to eq(0)
    expect(result).to be_success
  end

  it "отдельно возвращает stderr" do
    result = runner.call("echo ошибка >&2")

    expect(result.stderr.strip).to eq("ошибка")
    expect(result.stdout).to be_empty
  end

  it "сохраняет ненулевой код выхода" do
    result = runner.call("exit 42")

    expect(result.exit_code).to eq(42)
    expect(result).not_to be_success
  end

  describe "таймаут" do
    subject(:runner) { described_class.new(timeout: 0.2, poll_interval: 0.02) }

    it "бросает TimeoutError, не дожидаясь конца команды" do
      expect { runner.call("sleep 5") }.to raise_error(MiniAgent::TimeoutError, /превышено время ожидания/)
    end

    it "укладывается в разумное время вместо ожидания всей команды" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        runner.call("sleep 5")
      rescue MiniAgent::TimeoutError
        # ожидаемо
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2.0
    end

    it "убивает процесс, а не оставляет его в фоне" do
      marker = File.join(Dir.tmpdir, "mini_agent_kill_#{Process.pid}.txt")
      FileUtils.rm_f(marker)

      begin
        runner.call("sleep 1; echo дожил > #{marker}")
      rescue MiniAgent::TimeoutError
        # ожидаемо
      end
      sleep 1.5 # даём время «выжившему» процессу дописать файл

      expect(File.exist?(marker)).to be(false)
    ensure
      FileUtils.rm_f(marker)
    end
  end

  # Если читать stdout и stderr последовательно, команда с большим выводом
  # заблокируется на переполненном буфере пайпа и рантайм зависнет.
  it "не впадает в дедлок при выводе больше буфера пайпа" do
    result = runner.call("yes длинная-строка | head -n 20000")

    expect(result.stdout.lines.size).to eq(20_000)
    expect(result.exit_code).to eq(0)
  end

  it "не впадает в дедлок при большом выводе в stderr" do
    result = runner.call("yes ошибка | head -n 20000 >&2")

    expect(result.stderr.lines.size).to eq(20_000)
  end
end
