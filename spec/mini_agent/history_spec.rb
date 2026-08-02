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
end
