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

    # История целиком уходит модели через to_a, поэтому расход токенов
    # в сообщение класть нельзя — он поехал бы вместе с ней. В журнале же
    # он нужен: по нему видно, на каком ходу раздулся контекст.
    it "пишет расход токенов в журнал, но не в историю" do
      conversation = described_class.new(system_prompt: nil, transcript: transcript)

      conversation.assistant("ответ", usage: { "prompt_tokens" => 13 })

      expect(transcript).to have_received(:message).with(hash_including(usage: { "prompt_tokens" => 13 }))
      expect(conversation.to_a.last).not_to have_key(:usage)
    end

    it "без расхода запись не меняется" do
      conversation = described_class.new(system_prompt: nil, transcript: transcript)

      conversation.assistant("ответ")

      expect(transcript).to have_received(:message).with(hash_excluding(:usage))
    end

    # Журнал протоколирует то, что уходило модели, поэтому снятые сообщения
    # из него не вычёркиваются — вместо этого появляется отметка об откате.
    it "сообщает журналу об откате, а не переписывает его" do
      conversation = described_class.new(system_prompt: nil, transcript: transcript)
      mark = conversation.mark
      conversation.user("задача")
      conversation.assistant("ответ")

      conversation.rollback(mark)

      expect(transcript).to have_received(:message).exactly(2).times
      expect(transcript).to have_received(:rollback).with(2)
    end
  end

  describe "откат хода" do
    it "снимает всё, что добавилось после отметки" do
      conversation = described_class.new(system_prompt: "s")
      mark = conversation.mark
      conversation.user("задача")
      conversation.assistant("ответ")

      expect(conversation.rollback(mark)).to eq(2)
      expect(conversation.to_a.map { |m| m[:role] }).to eq(["system"])
    end

    it "не трогает историю, если после отметки ничего не появилось" do
      conversation = described_class.new(system_prompt: "s")

      expect(conversation.rollback(conversation.mark)).to eq(0)
      expect(conversation.size).to eq(1)
    end

    # После отката историей продолжают пользоваться — это и есть его смысл.
    it "оставляет историю пригодной для продолжения" do
      conversation = described_class.new(system_prompt: "s")
      mark = conversation.mark
      conversation.user("упавшая задача")
      conversation.rollback(mark)

      conversation.user("следующая задача")

      expect(conversation.to_a.map { |m| m[:content] }).to eq(["s", "следующая задача"])
    end
  end

  it "не даёт менять историю через возвращённый массив" do
    conversation = described_class.new(system_prompt: "s")
    conversation.to_a.first[:content] = "подмена"

    expect(conversation.last[:content]).to eq("s")
  end

  # Сообщения складываются хешем, а у push появился keyword-аргумент usage:.
  # Ruby разбирает `push(role: ..., content: ...)` без фигурных скобок как
  # keyword-аргументы, и сообщение уходило пустым — поймано только тем, что
  # упали все тесты Repl разом. Тест закрепляет, что роли на месте.
  it "кладёт сообщения всех ролей целиком, а не пустыми" do
    conversation = described_class.new(system_prompt: "правила")
    conversation.user("задача")
    conversation.assistant("ответ")
    conversation.tool("call_1", "вывод")

    expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant tool])
    expect(conversation.to_a.map { |m| m[:content] }).to eq(%w[правила задача ответ вывод])
  end
end
