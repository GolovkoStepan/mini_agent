# frozen_string_literal: true

RSpec.describe MiniAgent::Conversation do
  it "начинается с системного сообщения" do
    conversation = described_class.new(system_prompt: "правила")

    expect(conversation.to_a).to eq([{ role: "system", content: "правила" }])
  end

  it "не добавляет системное сообщение, если промпт равен nil" do
    expect(described_class.new(system_prompt: nil)).to be_empty
  end

  describe "контекст проекта" do
    # Шаблоны чата ряда моделей требуют, чтобы system-сообщение было ровно
    # одно и первое, и отвечают HTTP 400 на второе.
    it "дописывает контекст к системному промпту, а не отдельным сообщением" do
      conversation = described_class.new(system_prompt: "правила", project_context: "make spec")

      expect(conversation.size).to eq(1)
      expect(conversation.last[:content]).to include("правила")
      expect(conversation.last[:content]).to include("make spec")
    end

    # Без явной границы модель принимает описание за инструкции и начинает
    # выполнять то, что в нём написано, вместо задачи пользователя.
    it "размечает контекст блоком" do
      conversation = described_class.new(system_prompt: "правила", project_context: "make spec")

      expect(conversation.last[:content]).to include("<project_context>")
      expect(conversation.last[:content]).to include("</project_context>")
    end

    it "не меняет промпт, когда контекста нет" do
      conversation = described_class.new(system_prompt: "правила", project_context: nil)

      expect(conversation.last[:content]).to eq("правила")
    end

    it "не меняет промпт, когда контекст пуст" do
      conversation = described_class.new(system_prompt: "правила", project_context: "  \n ")

      expect(conversation.last[:content]).to eq("правила")
    end

    it "принимает контекст без системного промпта" do
      conversation = described_class.new(system_prompt: nil, project_context: "make spec")

      expect(conversation.last[:content]).to include("make spec")
    end
  end

  it "сохраняет порядок сообщений" do
    conversation = described_class.new(system_prompt: "s")
    conversation.user("привет")
    conversation.assistant("ответ")

    expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant])
  end

  it "использует символьные ключи" do
    conversation = described_class.new(system_prompt: "s")
    conversation.user("задача")

    expect(conversation.last.keys).to all(be_a(Symbol))
  end

  describe "#assistant" do
    it "не добавляет tool_calls, когда их нет" do
      conversation = described_class.new(system_prompt: nil)
      conversation.assistant("текст")

      expect(conversation.last).to eq({ role: "assistant", content: "текст" })
    end

    it "прикладывает tool_calls к сообщению" do
      calls = [{ "id" => "call_1", "function" => { "name" => "bash" } }]
      conversation = described_class.new(system_prompt: nil)
      conversation.assistant(nil, tool_calls: calls)

      expect(conversation.last[:tool_calls]).to eq(calls)
    end

    # API требует именно null, а не пустую строку, когда текста нет.
    it "превращает пустой текст в nil" do
      conversation = described_class.new(system_prompt: nil)
      conversation.assistant("", tool_calls: [{ "id" => "x" }])

      expect(conversation.last[:content]).to be_nil
    end
  end

  describe "#tool" do
    it "записывает ответ инструмента с идентификатором вызова" do
      conversation = described_class.new(system_prompt: nil)
      conversation.tool("call_7", "вывод")

      expect(conversation.last).to eq({ role: "tool", tool_call_id: "call_7", content: "вывод" })
    end
  end

  describe ".tool_call_id" do
    it "берёт идентификатор из ответа модели" do
      expect(described_class.tool_call_id({ "id" => "call_abc" })).to eq("call_abc")
    end

    it "генерирует идентификатор, если модель его не прислала" do
      expect(described_class.tool_call_id({})).to match(/\Acall_[0-9a-f]{16}\z/)
    end

    it "генерирует идентификатор, если он пустой" do
      expect(described_class.tool_call_id({ "id" => "" })).to match(/\Acall_[0-9a-f]{16}\z/)
    end
  end

  describe "журнал" do
    let(:transcript) { instance_spy(MiniAgent::Transcript) }

    it "отдаёт журналу каждое сообщение" do
      conversation = described_class.new(system_prompt: nil, transcript: transcript)
      conversation.user("задача")
      conversation.assistant("ответ")
      conversation.tool("call_1", "вывод")

      expect(transcript).to have_received(:message).exactly(3).times
    end

    # Системный промпт добавляется в конструкторе, до того как кто-либо
    # успел бы залогировать его снаружи, — а он и есть самое интересное,
    # когда разбираешься, почему модель повела себя странно.
    it "пишет и системный промпт" do
      described_class.new(system_prompt: "правила", transcript: transcript)

      expect(transcript).to have_received(:message).with(hash_including(role: "system"))
    end

    it "без журнала работает как прежде" do
      expect { described_class.new(system_prompt: nil).user("задача") }.not_to raise_error
    end
  end

  it "не даёт менять историю через возвращённый массив" do
    conversation = described_class.new(system_prompt: "s")
    conversation.to_a.first[:content] = "подмена"

    expect(conversation.last[:content]).to eq("s")
  end
end
