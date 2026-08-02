# frozen_string_literal: true

RSpec.describe MiniAgent::ProcessRunner do
  describe "рабочий каталог" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    it "выполняет команду в указанном каталоге" do
      runner = described_class.new(cwd: @dir)

      # Символические ссылки: на macOS /tmp ведёт в /private/tmp.
      expect(runner.call("pwd").stdout.strip).to eq(File.realpath(@dir))
    end

    it "по умолчанию работает в каталоге процесса" do
      runner = described_class.new

      expect(runner.call("pwd").stdout.strip).to eq(File.realpath(Dir.pwd))
    end

    # Dir.chdir сменил бы каталог всему агенту — и тому, где он ищет описание
    # проекта, и тому, куда пишет. Побочный эффект на весь процесс ради одной
    # команды здесь не нужен.
    it "не меняет каталог самого агента" do
      before = Dir.pwd
      described_class.new(cwd: @dir).call("pwd")

      expect(Dir.pwd).to eq(before)
    end

    it "видит файлы рабочего каталога" do
      File.write(File.join(@dir, "заметка.txt"), "содержимое")
      runner = described_class.new(cwd: @dir)

      expect(runner.call("cat заметка.txt").stdout).to eq("содержимое")
    end
  end

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

  # Ctrl+C во время команды. Проверяется настоящим процессом: смысл целиком
  # в том, переживёт ли он прерывание, а заглушка об этом ничего не скажет.
  describe "прерывание" do
    subject(:runner) { described_class.new(timeout: 10, poll_interval: 0.02) }

    it "пробрасывает Interrupt наверх" do
      interrupter = Thread.new do
        sleep 0.3
        Thread.main.raise(Interrupt)
      end

      expect { runner.call("sleep 5") }.to raise_error(Interrupt)
    ensure
      interrupter&.join
    end

    # Команда перехватывает INT и продолжает работу: сигнала от терминала ей
    # мало, нужен явный KILL — иначе она допишет файл уже после прерывания.
    it "убивает процесс, переживший сигнал" do
      marker = File.join(Dir.tmpdir, "mini_agent_int_#{Process.pid}.txt")
      FileUtils.rm_f(marker)
      interrupter = Thread.new do
        sleep 0.4
        Thread.main.raise(Interrupt)
      end

      begin
        runner.call("trap '' INT; sleep 1; echo дожил > #{marker}")
      rescue Interrupt
        # ожидаемо
      end
      interrupter.join
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
