# frozen_string_literal: true

RSpec.describe MiniAgent::TaskAnchor do
  let(:usage) { MiniAgent::Usage.new }

  # Окно 8192 даёт max_tokens 4096 (WINDOW_SHARE): промпт в 7000 токенов
  # означает занятость 11096 из 8192 — заведомо выше порога.
  let(:config) { MiniAgent::Config.new({ context_window: 8192 }, env: {}) }

  subject(:anchor) { described_class.new(config: config, usage: usage) }

  def talk
    MiniAgent::History.new.build.tap do |conversation|
      conversation.user("почини тесты")
      conversation.assistant("готово")
    end
  end

  def tight!(prompt_tokens = 7000)
    usage.add("prompt_tokens" => prompt_tokens, "completion_tokens" => 10, "total_tokens" => prompt_tokens + 10)
  end

  describe "пока места хватает" do
    it "не трогает историю" do
      conversation = talk
      usage.add("prompt_tokens" => 100, "completion_tokens" => 5, "total_tokens" => 105)

      expect(anchor.call(conversation, "почини тесты")).to be(false)
      expect(conversation.to_a.size).to eq(3)
    end

    # Первый ход задачи: usage ещё пуст, мерить заполнение нечем. Тот же
    # ответ, что у автоматического сворачивания, — пересчёт знаков в токены
    # отвергнут по всему проекту.
    it "молчит, пока сервер не сообщил ни одного usage" do
      expect(anchor.call(talk, "почини тесты")).to be(false)
    end

    it "молчит при неизвестном размере окна" do
      anchor = described_class.new(config: MiniAgent::Config.new({}, env: {}), usage: usage)
      tight!

      expect(anchor.call(talk, "почини тесты")).to be(false)
    end
  end

  describe "когда окно тесное" do
    it "кладёт задачу последним сообщением от пользователя" do
      conversation = talk
      tight!

      expect(anchor.call(conversation, "почини тесты")).to be(true)
      last = conversation.to_a.last
      expect(last[:role]).to eq("user")
      expect(last[:content]).to include("почини тесты")
    end

    # Дословно, а не пересказом: пересказ пришлось бы у кого-то спрашивать,
    # то есть тратить ход и давать модели ещё один шанс нафантазировать.
    it "повторяет задачу слово в слово" do
      conversation = talk
      tight!
      task = "перепиши README и не трогай ничего больше"

      anchor.call(conversation, task)

      expect(conversation.to_a.last[:content]).to include(task)
    end

    # Порог общий со сворачиванием: свой ставил бы якорь задолго до тесноты,
    # то есть добавлял бы по сообщению на ход через всю сессию.
    it "берёт порог из настроек, а не из своего числа" do
      config = MiniAgent::Config.new({ context_window: 8192, compact_at: "0.2" }, env: {})
      anchor = described_class.new(config: config, usage: usage)
      conversation = talk
      # 1000 + 4096 из 8192 — 62%: выше 0.2, но ниже умолчания 0.75.
      usage.add("prompt_tokens" => 1000, "completion_tokens" => 5, "total_tokens" => 1005)

      expect(anchor.call(conversation, "почини тесты")).to be(true)
    end
  end

  # Задача бывает пустой: интерактивный /compact и /init ходят тем же циклом
  # ходов, а якорь без задачи повторял бы пустоту.
  describe "без задачи" do
    it "ничего не кладёт" do
      conversation = talk
      tight!

      expect(anchor.call(conversation, nil)).to be(false)
      expect(anchor.call(conversation, "")).to be(false)
      expect(conversation.to_a.size).to eq(3)
    end
  end
end
