# frozen_string_literal: true

RSpec.describe MiniAgent::Initializer do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:dir) { Dir.mktmpdir }
  let(:config) { MiniAgent::Config.new({ cwd: dir }, env: {}) }
  let(:conversation) { MiniAgent::History.new.build }

  # Агент-заглушка: /init работает через обычный цикл ходов, и подменять
  # тут нужно именно его, а не клиента. Файл пишет блок — так же, как его
  # написала бы модель командой bash.
  let(:agent) do
    Class.new do
      attr_reader :tasks

      def initialize(&writer)
        @tasks = []
        @writer = writer
      end

      def run(task, conversation: nil)
        @tasks << task
        @writer&.call
        conversation
      end
    end
  end

  def initializer(agent_double, prompt: MiniAgent::Prompt::AutoApprove.new)
    described_class.new(agent: agent_double, config: config, ui: ui, prompt: prompt)
  end

  def written_agent(name: "AGENTS.md", content: "# Проект\n\nТесты: make spec\n")
    agent.new { File.write(File.join(dir, name), content) }
  end

  after { FileUtils.remove_entry(dir) }

  describe "создание описания" do
    it "просит модель описать проект и сообщает об успехе" do
      writer = written_agent
      initializer(writer).call(conversation)

      expect(writer.tasks.first).to include("AGENTS.md")
      expect(File.read(File.join(dir, "AGENTS.md"))).to include("make spec")
      expect(out.string).to include("Описание проекта записано", "AGENTS.md")
    end

    # Описание попадает в промпт при сборке истории, а та собрана на старте.
    # Молчать об этом нельзя: иначе кажется, что агент уже всё знает.
    it "предупреждает, что описание вступит в силу позже" do
      initializer(written_agent).call(conversation)

      expect(out.string).to include("вступит в силу после /clear")
    end

    it "возвращает историю, а не результат агента" do
      expect(initializer(written_agent).call(conversation)).to be(conversation)
    end

    # Пишем в AGENTS.md, даже когда описание ищется под двумя именами:
    # .mini_agent.md существует для чужого конфликта, решать его за
    # пользователя незачем.
    it "просит записать именно AGENTS.md" do
      writer = written_agent
      initializer(writer).call(conversation)

      expect(writer.tasks.first).not_to include(".mini_agent.md")
    end
  end

  # Модель охотно рапортует об успехе, не выполнив записи. Верить словам
  # нельзя, когда проверка стоит один File.file?.
  describe "модель не создала файл" do
    it "сообщает об этом, а не об успехе" do
      initializer(agent.new).call(conversation)

      expect(out.string).to include("не создала AGENTS.md")
      expect(out.string).not_to include("Описание проекта записано")
    end
  end

  describe "описание уже есть" do
    before { File.write(File.join(dir, "AGENTS.md"), "старое описание") }

    it "по отказу не трогает файл и не зовёт модель" do
      writer = written_agent
      initializer(writer, prompt: MiniAgent::Prompt::AutoDeny.new).call(conversation)

      expect(writer.tasks).to be_empty
      expect(File.read(File.join(dir, "AGENTS.md"))).to eq("старое описание")
      expect(out.string).to include("уже есть", "Отменено")
    end

    it "по согласию перезаписывает" do
      initializer(written_agent).call(conversation)

      expect(File.read(File.join(dir, "AGENTS.md"))).to include("make spec")
    end

    # Второе имя тоже считается существующим описанием: перезаписывать его
    # молча значило бы завести два описания разом.
    it "замечает .mini_agent.md" do
      FileUtils.rm(File.join(dir, "AGENTS.md"))
      File.write(File.join(dir, ".mini_agent.md"), "описание для этого агента")

      initializer(agent.new, prompt: MiniAgent::Prompt::AutoDeny.new).call(conversation)

      expect(out.string).to include(".mini_agent.md")
    end
  end

  # С --cwd агент работает не там, откуда запущен: описание, написанное
  # не в тот каталог, не найдётся при следующем запуске.
  it "проверяет рабочий каталог агента, а не каталог запуска" do
    File.write(File.join(dir, "AGENTS.md"), "старое")

    initializer(agent.new, prompt: MiniAgent::Prompt::AutoDeny.new).call(conversation)

    expect(out.string).to include("уже есть")
  end
end
