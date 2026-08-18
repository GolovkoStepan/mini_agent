# frozen_string_literal: true

RSpec.describe MiniAgent::History do
  it "по умолчанию строит историю с одним системным промптом" do
    conversation = described_class.new.build

    expect(conversation.to_a.map { |m| m[:role] }).to eq(["system"])
  end

  it "подмешивает описание проекта в системный промпт" do
    conversation = described_class.new(project_context: "тесты: make spec").build

    expect(conversation.last[:content]).to include("тесты: make spec")
  end

  # Тем же путём, что описание проекта: не пробросив каталог сюда, после
  # /clear и /compact агент снова начал бы его выдумывать — молча и до
  # конца сессии.
  it "подмешивает рабочий каталог в системный промпт" do
    conversation = described_class.new(cwd: "/срез/проект").build

    expect(conversation.last[:content]).to include("/срез/проект")
  end

  it "передаёт журнал новой истории" do
    transcript = instance_spy(MiniAgent::Transcript)

    described_class.new(transcript: transcript).build.user("задача")

    expect(transcript).to have_received(:message).with(hash_including(content: "задача"))
  end

  # Каждый вызов — отдельный диалог: именно на этом держится /clear.
  it "строит независимые истории" do
    history = described_class.new
    first = history.build
    first.user("задача")

    expect(history.build.size).to eq(1)
  end

  # Найдено живой проверкой: после «История очищена» /context показывал
  # прежние 16909 из 8192 (206%) при пустой истории и советовал звать
  # /compact. Число формально честное — промпт последнего запроса, — но
  # к новой истории оно не относится, и как «контекст сейчас» это ложь.
  describe "счётчик токенов" do
    it "забывает размер контекста при новой истории" do
      history = described_class.new
      history.usage.add({ "prompt_tokens" => 6000, "completion_tokens" => 100 })

      history.build

      expect(history.usage.context).to eq(0)
    end

    # Откатывать потраченное нельзя: серверу за те запросы уплачено. Тот же
    # принцип, что у провалившегося хода, — счёт показывает, что произошло.
    it "не забывает потраченное" do
      history = described_class.new
      history.usage.add({ "prompt_tokens" => 6000, "completion_tokens" => 100 })

      history.build

      expect(history.usage.sent).to eq(6000)
      expect(history.usage.generated).to eq(100)
      expect(history.usage).not_to be_empty
    end
  end
end
