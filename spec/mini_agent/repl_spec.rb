# frozen_string_literal: true

RSpec.describe MiniAgent::Repl do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:config) { MiniAgent::Config.new({ max_turns: 3 }, env: {}) }
  let(:client) { instance_double(MiniAgent::LLMClient) }
  let(:tools) { MiniAgent::ToolRegistry.new }
  let(:agent) { MiniAgent::Agent.new(config: config, client: client, tools: tools, ui: ui) }

  def repl(input)
    reader = MiniAgent::LineReader.new(input: StringIO.new(input), output: out)
    described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader)
  end

  describe "цикл задач" do
    it "выполняет задачи из ввода и выходит по exit" do
      allow(client).to receive(:chat).and_return(["ответ", []])

      repl("первая задача\nexit\n").run

      expect(client).to have_received(:chat).once
      expect(out.string).to include("До свидания!")
    end

    it "накапливает историю между задачами" do
      allow(client).to receive(:chat).and_return(["раз", []], ["два", []])

      conversation = repl("задача 1\nзадача 2\nexit\n").run

      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant user assistant])
    end

    it "пропускает пустые строки" do
      allow(client).to receive(:chat).and_return(["ответ", []])

      repl("\n   \nзадача\nexit\n").run

      expect(client).to have_received(:chat).once
    end

    # Ctrl+D закрывает поток ввода.
    it "выходит при обрыве ввода" do
      allow(client).to receive(:chat)

      expect { repl("").run }.not_to raise_error
      expect(out.string).to include("До свидания!")
    end
  end

  describe "Ctrl+C на приглашении" do
    # Читатель, отдающий Interrupt вместо строки: ровно так ведёт себя
    # Reline, когда пользователь жмёт Ctrl+C посреди набора.
    def reader_raising(*script)
      steps = script.dup
      reader = instance_double(MiniAgent::LineReader)
      allow(reader).to receive(:gets) do
        step = steps.shift
        raise Interrupt if step == :interrupt

        step
      end
      reader
    end

    def repl_with(reader)
      described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader)
    end

    it "первый Ctrl+C не выходит, а подсказывает" do
      allow(client).to receive(:chat)

      repl_with(reader_raising(:interrupt, nil)).run

      expect(out.string).to include("Ещё раз Ctrl+C — выход")
      expect(out.string).to include("До свидания!")
    end

    it "второй Ctrl+C подряд выходит" do
      allow(client).to receive(:chat)

      repl_with(reader_raising(:interrupt, :interrupt, "не дойдёт\n")).run

      expect(out.string).to include("До свидания!")
      expect(client).not_to have_received(:chat)
    end

    # Две отмены, разделённые работой, — это не намерение выйти.
    it "сбрасывает счётчик после обычной строки" do
      allow(client).to receive(:chat).and_return(["ответ", []])

      repl_with(reader_raising(:interrupt, "задача\n", :interrupt, nil)).run

      expect(client).to have_received(:chat).once
      expect(out.string.scan("Ещё раз Ctrl+C").size).to eq(2)
    end
  end

  describe "команды" do
    it "не отдаёт команды модели" do
      allow(client).to receive(:chat)

      repl("/tools\n/model\nexit\n").run

      expect(client).not_to have_received(:chat)
    end

    it "по /clear начинает историю заново" do
      allow(client).to receive(:chat).and_return(["раз", []], ["два", []])

      conversation = repl("задача 1\n/clear\nзадача 2\nexit\n").run

      expect(out.string).to include("История очищена.")
      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant])
    end

    # /clear заводит историю заново, и журнал должен уехать в неё вместе с
    # остальным: иначе запись обрывалась бы на первой же очистке, причём молча.
    it "продолжает писать журнал после /clear" do
      allow(client).to receive(:chat).and_return(["ответ", []])
      transcript = instance_spy(MiniAgent::Transcript)
      agent = MiniAgent::Agent.new(
        config: config, client: client, tools: tools, ui: ui,
        history: MiniAgent::History.new(transcript: transcript)
      )
      reader = MiniAgent::LineReader.new(input: StringIO.new("/clear\nзадача\nexit\n"), output: out)

      described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader).run

      expect(transcript).to have_received(:message).with(hash_including(role: "user", content: "задача"))
    end

    # После /clear описание проекта должно вернуться в новую историю:
    # иначе агент забывал бы про AGENTS.md до конца сессии.
    it "сохраняет описание проекта после /clear" do
      allow(client).to receive(:chat)
      agent = MiniAgent::Agent.new(
        config: config, client: client, tools: tools, ui: ui,
        history: MiniAgent::History.new(project_context: "тесты: make spec")
      )
      reader = MiniAgent::LineReader.new(input: StringIO.new("/clear\nexit\n"), output: out)

      conversation = described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader).run

      expect(conversation.to_a.first[:content]).to include("тесты: make spec")
    end
  end
end
