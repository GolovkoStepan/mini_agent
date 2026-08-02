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

  describe "/clear" do
    it "просит очистить историю" do
      expect(commands.call("/clear")).to eq(:clear)
    end
  end
end
