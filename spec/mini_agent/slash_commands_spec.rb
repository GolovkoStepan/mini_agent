# frozen_string_literal: true

RSpec.describe MiniAgent::SlashCommands do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:config) { MiniAgent::Config.new({ model: "qwen-test", base_url: "http://srv:1234/v1" }, env: {}) }
  let(:tools) { MiniAgent::ToolRegistry.new([double(name: "bash", schema: {})]) }

  subject(:commands) { described_class.new(config: config, tools: tools, ui: ui) }

  describe "распознавание" do
    it "обычный текст отдаёт модели" do
      expect(commands.call("покажи содержимое lib")).to eq(:task)
    end

    # Задача «покажи, что в /usr/bin» не должна превращаться в команду.
    it "не считает командой строку, где слэш не единственное слово" do
      expect(commands.call("покажи /usr/bin")).to eq(:task)
      expect(commands.call("/usr/bin")).to eq(:task)
    end

    it "сообщает о неизвестной команде, не отдавая её модели" do
      expect(commands.call("/нетакой")).to eq(:handled)
      expect(out.string).to include("Неизвестная команда")
    end

    it "не различает регистр" do
      expect(commands.call("/HELP")).to eq(:handled)
    end
  end

  describe "выход" do
    it "по /exit и /quit" do
      expect(commands.call("/exit")).to eq(:exit)
      expect(commands.call("/quit")).to eq(:exit)
    end

    # До появления команд это был единственный способ выйти.
    it "по слову exit без слэша" do
      expect(commands.call("exit")).to eq(:exit)
      expect(commands.call("EXIT")).to eq(:exit)
    end
  end

  describe "/help" do
    it "перечисляет команды" do
      commands.call("/help")

      expect(out.string).to include("/help", "/clear", "/model", "/tools", "/exit")
    end

    # Список для справки и разбор в case — разные места; тест ловит их
    # рассинхронизацию, иначе /help обещал бы несуществующую команду.
    it "все обещанные команды действительно распознаются" do
      described_class::COMMANDS.each_key do |name|
        expect(commands.call("/#{name}")).not_to eq(:task), "/#{name} не распознана"
        expect(out.string).not_to include("Неизвестная команда")
      end
    end
  end

  describe "/model" do
    it "показывает модель, сервер и рабочий каталог" do
      expect(commands.call("/model")).to eq(:handled)

      expect(out.string).to include("qwen-test", "http://srv:1234/v1", Dir.pwd)
    end
  end

  describe "/tools" do
    it "перечисляет доступные инструменты" do
      expect(commands.call("/tools")).to eq(:handled)

      expect(out.string).to include("bash")
    end
  end

  describe "/usage" do
    let(:usage) { MiniAgent::Usage.new }

    subject(:commands) { described_class.new(config: config, tools: tools, ui: ui, usage: usage) }

    it "показывает отправленное, сгенерированное и текущий контекст" do
      usage.add({ "prompt_tokens" => 13, "completion_tokens" => 5 })
      usage.add({ "prompt_tokens" => 57, "completion_tokens" => 7 })

      expect(commands.call("/usage")).to eq(:handled)
      expect(out.string).to include("70", "12", "57")
    end

    # Три нуля читаются как «модель ничего не потратила», хотя её ещё
    # не спрашивали. Это разные вещи, и говорить надо прямо.
    it "до первого запроса говорит, что считать нечего" do
      expect(commands.call("/usage")).to eq(:handled)

      expect(out.string).to include("не было")
      expect(out.string).not_to include("0")
    end
  end

  describe "/clear" do
    it "просит очистить историю" do
      expect(commands.call("/clear")).to eq(:clear)
    end
  end

  describe "/context" do
    let(:conversation) do
      MiniAgent::Conversation.new(system_prompt: "промпт").tap do |talk|
        talk.user("почини тесты")
        talk.assistant("готово")
      end
    end

    it "показывает разбивку по категориям" do
      expect(commands.call("/context", conversation: conversation)).to eq(:handled)

      expect(out.string).to include("системный промпт", "задачи", "ответы модели", "всего")
    end

    # История принадлежит Repl и меняется по /clear и /compact. Хранить её
    # в поле значило бы синхронизировать два места; отчёт по устаревшей
    # истории был бы неотличим от верного.
    it "берёт историю из аргумента, а не из своего состояния" do
      other = MiniAgent::Conversation.new(system_prompt: "промпт")
      other.user("совсем другая задача")

      commands.call("/context", conversation: conversation)
      commands.call("/context", conversation: other)

      # Три сообщения в первой истории, два во второй: отчёт следует
      # за переданной историей, а не за запомненной.
      expect(out.string.scan(/Контекст: (\d+)/).flatten).to eq(%w[3 2])
    end

    it "без истории не падает" do
      expect(commands.call("/context")).to eq(:handled)
      expect(out.string).to include("пуст")
    end

    context "с расходом токенов" do
      let(:usage) { MiniAgent::Usage.new }

      subject(:commands) { described_class.new(config: config, tools: tools, ui: ui, usage: usage) }

      it "показывает размер промпта по данным сервера" do
        usage.add({ "prompt_tokens" => 57, "completion_tokens" => 7 })

        commands.call("/context", conversation: conversation)

        expect(out.string).to include("57 токенов")
      end

      # Ноль означал бы «промпт пустой». Сервер мог не прислать usage вовсе —
      # это другое, и говорить об этом надо иначе.
      it "молчит о токенах, когда сервер их не присылал" do
        commands.call("/context", conversation: conversation)

        expect(out.string).to include("не сообщал")
      end
    end
  end

  describe "/compact" do
    # Сворачивание идёт к модели, а у команд нет ни клиента, ни History:
    # это работа агента, здесь только вердикт.
    it "просит свернуть диалог" do
      expect(commands.call("/compact")).to eq(:compact)
    end
  end

  describe "/init" do
    # Описание проекта агент собирает целым циклом ходов с bash — тем более
    # не дело команд, чем сворачивание.
    it "просит описать проект" do
      expect(commands.call("/init")).to eq(:init)
    end
  end
end
