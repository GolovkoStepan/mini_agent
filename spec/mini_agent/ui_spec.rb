# frozen_string_literal: true

RSpec.describe MiniAgent::UI do
  let(:out) { StringIO.new }

  subject(:ui) { described_class.new(out: out, tty: false) }

  it "не раскрашивает вывод вне терминала" do
    ui.error("сломалось")

    expect(out.string).to eq("● сломалось\n")
    expect(out.string).not_to include("\e[")
  end

  it "раскрашивает вывод в терминале" do
    tty_ui = described_class.new(out: out, tty: true)
    tty_ui.error("сломалось")

    expect(out.string).to include("\e[31m")
  end

  it "помечает маркером ответ ассистента" do
    ui.assistant("готово")

    expect(out.string).to include("● готово")
  end

  describe "#tool_call" do
    it "показывает команду для bash" do
      ui.tool_call("bash", { "command" => "ls -la" })

      expect(out.string).to include("● Bash(ls -la)")
    end

    it "показывает аргументы JSON для прочих инструментов" do
      ui.tool_call("search", { "query" => "ruby" })

      expect(out.string).to include('{"query":"ruby"}')
    end
  end

  describe "#tool_result" do
    it "показывает короткий вывод целиком" do
      ui.tool_result("одна строка\n")

      expect(out.string).to include("⎿ одна строка")
      expect(out.string).not_to include("+")
    end

    it "обрезает длинный вывод для читаемости" do
      ui.tool_result((1..50).map { |i| "строка #{i}" }.join("\n"))

      expect(out.string).to include("строка 5")
      expect(out.string).not_to include("строка 6")
      expect(out.string).to include("… +45 строк")
    end

    # «+1 строк» — та же недоделка, что и «34 знаков», просто замеченная
    # позже: 45 скрытых строк случайно попадали в верную форму.
    it "согласует число скрытых строк" do
      ui.tool_result((1..6).map { |i| "строка #{i}" }.join("\n"))

      expect(out.string).to include("… +1 строка")
    end

    # Код выхода нужен модели всегда, человеку — только когда команда упала.
    it "не показывает нулевой код выхода" do
      ui.tool_result("Код выхода: 0\nвсё хорошо\n")

      expect(out.string).to include("⎿ всё хорошо")
      expect(out.string).not_to include("код выхода")
    end

    it "помечает ненулевой код выхода" do
      ui.tool_result("Код выхода: 1\ncat: нет файла\n")

      expect(out.string).to include("⎿ код выхода 1")
      expect(out.string).to include("cat: нет файла")
    end

    # Пустой stdout перед секцией STDERR давал пустую строку в блоке.
    it "не оставляет пустую строку при выводе только в stderr" do
      ui.tool_result("Код выхода: 1\n\nSTDERR:\ncat: нет файла\n")

      expect(out.string).not_to match(/⎿ код выхода 1\n\s*\n/)
      expect(out.string).to include("STDERR:")
    end

    # Пробелы в начале строки выравнивают колонки (wc, ls) — их резать нельзя.
    it "сохраняет ведущие пробелы выравнивания" do
      ui.tool_result("Код выхода: 0\n     150 agent.rb\n      46 color.rb\n")

      expect(out.string).to include("⎿      150 agent.rb")
    end
  end

  describe "#context" do
    def report(project_context: nil, usage: nil)
      talk = MiniAgent::Conversation.new(system_prompt: "промпт", project_context: project_context)
      talk.user("почини тесты")
      MiniAgent::ContextReport.new(talk, usage: usage)
    end

    it "печатает категории, доли и итог" do
      ui.context(report)

      expect(out.string).to include("Контекст: 2 сообщения", "системный промпт", "задачи", "всего", "%")
    end

    # «34 знаков» в целиком русском интерфейсе читается как недоделка ровно
    # там, где всё остальное выверено. Найдено живой проверкой /context.
    it "согласует числительные" do
      talk = MiniAgent::Conversation.new(system_prompt: "a" * 34)
      talk.user("b")

      ui.context(MiniAgent::ContextReport.new(talk))

      expect(out.string).to include("34 знака", "1 знак", "35 знаков")
      expect(out.string).not_to include("34 знаков", "1 знаков")
    end

    it "показывает описание проекта отдельной строкой" do
      ui.context(report(project_context: "тесты: make spec"))

      expect(out.string).to include("описание проекта")
    end

    it "печатает токены по данным сервера" do
      usage = MiniAgent::Usage.new
      usage.add({ "prompt_tokens" => 57, "completion_tokens" => 7 })

      ui.context(report(usage: usage))

      expect(out.string).to include("57 токенов")
    end

    # Ноль означал бы «промпт пустой», а не «измерить нечем».
    it "без данных сервера говорит об этом прямо, а не печатает ноль" do
      ui.context(report)

      expect(out.string).to include("не сообщал")
      expect(out.string).not_to include("0 токенов")
    end

    it "на пустом контексте не рисует таблицу" do
      empty = MiniAgent::ContextReport.new(MiniAgent::Conversation.new(system_prompt: nil))

      ui.context(empty)

      expect(out.string).to include("пуст")
      expect(out.string).not_to include("всего")
    end

    it "предупреждает, когда место занято описанием проекта" do
      ui.context(report(project_context: "описание " * 200))

      expect(out.string).to include("/compact его не тронет")
    end
  end

  describe "#with_spinner" do
    it "возвращает значение блока" do
      expect(ui.with_spinner { 42 }).to eq(42)
    end

    # Вне TTY анимация не нужна, а лишний поток делает тесты недетерминированными.
    it "не создаёт поток вне терминала" do
      before_count = Thread.list.size
      ui.with_spinner { expect(Thread.list.size).to eq(before_count) }
    end

    it "пробрасывает исключение блока" do
      expect { ui.with_spinner { raise ArgumentError, "сбой" } }.to raise_error(ArgumentError, "сбой")
    end

    context "в терминале" do
      subject(:ui) { described_class.new(out: out, tty: true, spinner_interval: 0.01) }

      it "останавливает поток после блока" do
        before_count = Thread.list.size
        ui.with_spinner { sleep 0.05 }

        expect(Thread.list.size).to eq(before_count)
        expect(out.string).to include("Думаю")
      end

      # Номер хода показывается только здесь и стирается вместе со спиннером.
      it "подмешивает строку состояния" do
        ui.status = "ход 2/10"
        ui.with_spinner { sleep 0.05 }

        expect(out.string).to include("ход 2/10")
      end

      # ensure обязан снять спиннер даже при исключении, иначе поток
      # останется висеть до конца процесса.
      it "останавливает поток при исключении в блоке" do
        before_count = Thread.list.size

        expect { ui.with_spinner { raise "сбой" } }.to raise_error("сбой")
        expect(Thread.list.size).to eq(before_count)
      end
    end
  end
end
