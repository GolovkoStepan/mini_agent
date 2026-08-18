# frozen_string_literal: true

RSpec.describe MiniAgent::AutoCompactor do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:compactor) { instance_double(MiniAgent::Compactor) }
  let(:history) { MiniAgent::History.new }
  let(:usage) { MiniAgent::Usage.new }

  # Окно 8192 даёт max_tokens 4096 (WINDOW_SHARE). Промпт в 7000 токенов
  # означает занятость 11096 из 8192 — заведомо выше порога WARN_AT.
  let(:config) { MiniAgent::Config.new({ context_window: 8192 }, env: {}) }

  subject(:auto) { described_class.new(compactor: compactor, config: config, ui: ui, usage: usage) }

  # Теснота меряется по usage сервера, а не по нашему счёту знаков:
  # без ответа сервера мерить нечем, и это отдельно проверяется ниже.
  def tight!(prompt_tokens = 7000)
    usage.add("prompt_tokens" => prompt_tokens, "completion_tokens" => 10, "total_tokens" => prompt_tokens + 10)
  end

  def talk
    history.build.tap do |conversation|
      conversation.user("почини тесты")
      conversation.assistant("готово")
    end
  end

  # Свёрнутая история: короче исходной, как и полагается после сворачивания.
  def summary
    MiniAgent::History.new.build.tap { |conversation| conversation.user("Резюме.") }
  end

  describe "пока места хватает" do
    it "не трогает историю и не ходит к модели" do
      conversation = talk
      usage.add("prompt_tokens" => 100, "completion_tokens" => 5, "total_tokens" => 105)

      expect(auto.call(conversation)).to be(conversation)
      expect(out.string).to be_empty
    end

    # Первый ход задачи: usage ещё пуст, мерить заполнение нечем. Считать
    # это «места полно» — единственный честный вариант: пересчёт знаков
    # в токены отвергнут по всему проекту.
    it "молчит, пока сервер не сообщил ни одного usage" do
      conversation = talk

      expect(auto.call(conversation)).to be(conversation)
    end

    it "молчит при неизвестном размере окна" do
      config = MiniAgent::Config.new({}, env: {})
      auto = described_class.new(compactor: compactor, config: config, ui: ui, usage: usage)
      conversation = talk
      tight!

      expect(auto.call(conversation)).to be(conversation)
    end
  end

  describe "когда окно кончается" do
    before { tight! }

    it "сворачивает диалог и отдаёт новую историю" do
      folded = summary
      allow(compactor).to receive(:call).and_return(folded)

      expect(auto.call(talk)).to be(folded)
    end

    # До запроса, а не после: сворачивание стоит целого хода к модели,
    # и молчаливая пауза посреди задачи выглядит зависанием.
    it "предупреждает заранее и называет заполнение" do
      allow(compactor).to receive(:call).and_return(summary)

      auto.call(talk)

      expect(out.string).to include("Окно заполнено на 135%")
      expect(out.string).to include("сворачиваю диалог")
    end
  end

  describe "выключатель" do
    it "не сворачивает при --no-auto-compact" do
      config = MiniAgent::Config.new({ context_window: 8192, auto_compact: false }, env: {})
      auto = described_class.new(compactor: compactor, config: config, ui: ui, usage: usage)
      conversation = talk
      tight!
      allow(compactor).to receive(:call)

      expect(auto.call(conversation)).to be(conversation)
      expect(compactor).not_to have_received(:call)
    end
  end

  # Теснота сама по себе не проходит: на следующем ходу условие выполнится
  # снова. Без признака «сдались» агент упирался бы в ту же стену каждый ход,
  # печатая одно и то же предупреждение до конца задачи.
  describe "отказ от дальнейших попыток" do
    before { tight! }

    it "сдаётся, когда свернуть не удалось" do
      conversation = talk
      allow(compactor).to receive(:call) { |given| given }

      expect(auto.call(conversation)).to be(conversation)
      expect(out.string).to include("дальше работаю без автоматического сворачивания")
    end

    it "не пробует второй раз после отказа" do
      allow(compactor).to receive(:call) { |given| given }

      auto.call(talk)
      auto.call(talk)

      expect(compactor).to have_received(:call).once
    end

    # Резюме бывает не короче свёрнутого — на коротком диалоге это обычное
    # дело (COMPACT_GREW). Повторять бессмысленно: на вход придёт то же самое.
    it "сдаётся, когда резюме не короче свёрнутого" do
      long = MiniAgent::History.new.build
      long.user("очень длинное резюме, которое не короче исходного диалога" * 20)
      allow(compactor).to receive(:call).and_return(long)

      expect(auto.call(talk)).to be(long), "свёрнутое остаётся свёрнутым, сдача — не откат"
      expect(out.string).to include("Сворачивать больше нечего")
    end

    # Найдено живой проверкой, а не рассуждением: 1794 знака → 1514 формально
    # короче, но ход к модели потрачен и нить задачи потеряна — ответ после
    # такого сворачивания съехал на «чем ещё помочь». Выигрыш должен быть
    # ощутимым (MIN_GAIN), иначе сворачивать незачем.
    it "сдаётся, когда выигрыш незначителен" do
      long = history.build.tap { |c| c.user("подробный разбор задачи " * 500) }
      barely = MiniAgent::History.new.build.tap do |c|
        c.user("х" * (MiniAgent::ContextReport.new(long).total * 0.85).to_i)
      end
      allow(compactor).to receive(:call).and_return(barely)

      expect(auto.call(long)).to be(barely)
      expect(out.string).to include("Сворачивать больше нечего")
    end

    it "печатает сообщение об отказе один раз" do
      allow(compactor).to receive(:call) { |given| given }

      auto.call(talk)
      auto.call(talk)

      expect(out.string.scan("дальше работаю без автоматического сворачивания").size).to eq(1)
    end
  end

  # Свернуть можно только сам диалог: описание проекта пересобирается из файла
  # и переживает сворачивание целиком. Запрос к модели ушёл бы впустую.
  describe "когда окно занято описанием проекта" do
    before { tight! }

    let(:history) { MiniAgent::History.new(project_context: "П" * 5000) }

    it "не тратит запрос и говорит, что лечится файлом" do
      conversation = talk
      allow(compactor).to receive(:call)

      expect(auto.call(conversation)).to be(conversation)
      expect(compactor).not_to have_received(:call)
      expect(out.string).to include("занято оно описанием проекта")
    end

    it "не советует того, что не поможет" do
      allow(compactor).to receive(:call)

      auto.call(talk)

      expect(out.string).not_to include("сворачиваю диалог")
    end
  end
end
