# frozen_string_literal: true

RSpec.describe MiniAgent::UI do
  let(:out) { StringIO.new }

  subject(:ui) { described_class.new(out: out, tty: false) }

  it "не раскрашивает вывод вне терминала" do
    ui.error("сломалось")

    expect(out.string).to eq("сломалось\n")
    expect(out.string).not_to include("\e[")
  end

  it "раскрашивает вывод в терминале" do
    tty_ui = described_class.new(out: out, tty: true)
    tty_ui.error("сломалось")

    expect(out.string).to include("\e[31m")
  end

  it "рисует баннер хода" do
    ui.banner("Ход 1")

    expect(out.string).to include("Ход 1")
    expect(out.string.lines.size).to eq(3)
  end

  describe "#tool_call" do
    it "показывает команду для bash" do
      ui.tool_call("bash", { "command" => "ls -la" })

      expect(out.string).to include("Команда: ls -la")
    end

    it "показывает аргументы JSON для прочих инструментов" do
      ui.tool_call("search", { "query" => "ruby" })

      expect(out.string).to include('{"query":"ruby"}')
    end
  end

  describe "#tool_result" do
    it "показывает короткий вывод целиком" do
      ui.tool_result("одна строка\n")

      expect(out.string).to include("одна строка")
      expect(out.string).not_to include("обрезано")
    end

    it "обрезает длинный вывод для читаемости" do
      ui.tool_result((1..50).map { |i| "строка #{i}" }.join("\n"))

      expect(out.string).to include("обрезано")
      expect(out.string).to include("строка 10")
      expect(out.string).not_to include("строка 11")
      expect(out.string).to include("из 50")
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
