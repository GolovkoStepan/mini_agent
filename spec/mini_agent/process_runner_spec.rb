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

    # Проверка именно на скорость возврата. Прошлая версия теста этого не
    # ловила: там команда жила секунду, и зависание длиной в неё же выглядело
    # нормой. Зависание тянется ровно столько, сколько живёт команда, поэтому
    # брать надо заведомо долгую.
    it "отдаёт управление сразу, а не ждёт конца команды" do
      interrupter = Thread.new do
        sleep 0.4
        Thread.main.raise(Interrupt)
      end

      elapsed = measure do
        expect { runner.call("trap '' INT; sleep 60") }.to raise_error(Interrupt)
      end

      expect(elapsed).to be < 5
    ensure
      interrupter&.join
      system("pkill -f 'sleep 60' >/dev/null 2>&1")
    end
  end

  # Вывод команды — произвольные байты. Ruby помечает его UTF-8, не проверяя
  # содержимого, и такая строка доходит до JSON.generate, где роняет агента
  # целиком (проверено живьём на `head -c 30 /bin/ls`).
  describe "двоичный вывод" do
    it "возвращает строку, годную для JSON" do
      result = runner.call("head -c 40 /bin/ls")

      expect(result.stdout).to be_valid_encoding
      expect { JSON.generate({ content: result.stdout }) }.not_to raise_error
    end

    it "то же самое для stderr" do
      result = runner.call("head -c 40 /bin/ls >&2")

      expect(result.stderr).to be_valid_encoding
    end

    it "не трогает обычный текст" do
      expect(runner.call("echo привет").stdout.strip).to eq("привет")
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

  # Команда оставляет после себя живой фоновый процесс — обычное дело для
  # `команда &` и для всего, что запускает демона. Он наследует конец пайпа,
  # и пока он жив, EOF не приходит: без своей группы процессов и ограниченного
  # ожидания агент вис ровно на время жизни этого потомка. Найдено живой
  # проверкой; тесты пропускали это, потому что в них команда жила секунду.
  # Защит здесь две, и проверяются они разными примерами. Убийство группы
  # закреплено «отдаёт вывод» и «убивает потомков» — они падают, стоит вернуть
  # KILL по одному pid. Ограниченное ожидание в drain закреплено замерами
  # времени: они падают, только если снять и его, потому что оно и есть
  # страховка на случай ускользнувшего потомка.
  describe "команда с фоновым потомком" do
    # Заведомо дольше любого разумного ожидания в этих тестах: если правка
    # снята, замер упрётся в него, а не в реальное время работы.
    let(:orphan) { "sleep 60" }

    after { system("pkill -f '#{orphan}' >/dev/null 2>&1") }

    it "возвращает управление сразу после выхода команды" do
      elapsed = measure { runner.call("#{orphan} & echo готово") }

      expect(elapsed).to be < 5
    end

    # Вывод не должен пропасть из-за того, что пайп остался открытым:
    # IO#read ждал бы EOF и вернул пустую строку.
    it "отдаёт вывод команды, а не теряет его" do
      expect(runner.call("#{orphan} & echo привет").stdout).to eq("привет\n")
    end

    it "укладывается в таймаут, а не ждёт потомка" do
      quick = described_class.new(timeout: 0.5)

      elapsed = measure do
        expect { quick.call("#{orphan} & wait") }.to raise_error(MiniAgent::TimeoutError)
      end

      expect(elapsed).to be < 5
    end

    # KILL по одному bash не достаёт его детей: убивать надо группу.
    it "убивает потомков вместе с командой" do
      marker = File.join(Dir.tmpdir, "mini_agent_orphan_#{Process.pid}.txt")
      FileUtils.rm_f(marker)
      quick = described_class.new(timeout: 0.5)

      begin
        quick.call("(sleep 1; echo дожил > #{marker}) & wait")
      rescue MiniAgent::TimeoutError
        # ожидаемо
      end
      sleep 2 # даём «выжившему» потомку время дописать файл

      expect(File.exist?(marker)).to be(false)
    ensure
      FileUtils.rm_f(marker)
    end
  end

  def measure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end
