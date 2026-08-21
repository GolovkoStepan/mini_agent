# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::PlanEditor do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  # Настоящий редактор захватил бы терминал и подвесил прогон, поэтому
  # запуск инъектируется. Сюда же попадает и строка команды целиком —
  # проверять её иначе нечем.
  let(:commands) { [] }

  def editor(env, result: true, &edit)
    runner = lambda do |command|
      commands << command
      edit&.call
      result
    end
    described_class.new(ui: ui, env: env, runner: runner)
  end

  def plan_file(text = "1. Прочитать.")
    MiniAgent::PlanStore.new(dir: @dir).save(text, task: "как добавить X?")
  end

  describe "выбор редактора" do
    it "берёт EDITOR" do
      editor({ "EDITOR" => "nano" }).call(plan_file)

      expect(commands.first).to start_with("nano ")
    end

    # Порядок тот же, что у git: VISUAL означает полноэкранный редактор,
    # EDITOR исторически мог быть строчным.
    it "предпочитает VISUAL" do
      editor({ "VISUAL" => "vim", "EDITOR" => "ed" }).call(plan_file)

      expect(commands.first).to start_with("vim ")
    end

    # Своего умолчания нет намеренно: vi запирает в себе того, кто не знает,
    # как из него выйти, — и делает это поверх уже составленного плана.
    it "отказывается, когда редактор не задан" do
      expect(editor({}).call(plan_file)).to be_nil
      expect(out.string).to include("не заданы ни VISUAL, ни EDITOR")
    end

    # `EDITOR= mini_agent` иначе запустил бы оболочку от пустой строки.
    it "считает пустое значение незаданным" do
      expect(editor({ "EDITOR" => "  " }).call(plan_file)).to be_nil
    end

    # В EDITOR кладут и «code -w», и «emacsclient -nw»: команда с аргументами
    # обязана работать, поэтому запуск идёт строкой, а не списком.
    it "передаёт команду с аргументами как есть" do
      editor({ "EDITOR" => "code -w" }).call(plan_file)

      expect(commands.first).to start_with("code -w ")
    end

    it "экранирует путь" do
      path = File.join(@dir, "план с пробелом.md")
      File.write(path, "# задача\n\nплан\n")
      editor({ "EDITOR" => "nano" }).call(path)

      expect(commands.first).to include(Shellwords.escape(path))
    end
  end

  describe "перечитывание файла" do
    it "возвращает исправленный текст без шапки" do
      path = plan_file
      edited = editor({ "EDITOR" => "nano" }) { File.write(path, "# как добавить X?\nДата: сейчас\n\n1. Иначе.\n") }

      expect(edited.call(path)).to eq("1. Иначе.")
    end

    # Код возврата редактора не отменяет чтения: файл мог быть сохранён
    # до сбоя, и он вернее нашей памяти о прежнем тексте.
    it "перечитывает файл и после сбоя редактора" do
      path = plan_file
      result = editor({ "EDITOR" => "nano" }, result: false) { File.write(path, "правка") }.call(path)

      expect(result).to eq("правка")
      expect(out.string).to include("Редактор завершился с ошибкой")
    end

    it "предупреждает, когда файл исчез" do
      path = plan_file
      expect(editor({ "EDITOR" => "nano" }) { File.delete(path) }.call(path)).to be_nil
      expect(out.string).to include("Не удалось перечитать план")
    end
  end

  # Файла нет, когда его не удалось записать (права на каталог). Править
  # тогда нечего, но и рушить сессию не из-за чего.
  it "отказывается без файла" do
    expect(editor({ "EDITOR" => "nano" }).call(nil)).to be_nil
    expect(out.string).to include("Править нечего")
    expect(commands).to be_empty
  end
end
