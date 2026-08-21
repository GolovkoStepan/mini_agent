# frozen_string_literal: true

RSpec.describe MiniAgent::Compactor do
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }
  let(:client) { double(:client) }
  let(:history) { MiniAgent::History.new }

  subject(:compactor) { described_class.new(client: client, history: history, ui: ui) }

  # Непустой диалог, который есть что сворачивать.
  def talk(history_object = history)
    history_object.build.tap do |conversation|
      conversation.user("почини тесты")
      conversation.assistant("готово, поправил spec/agent_spec.rb")
    end
  end

  def answer(content, usage: nil, finish_reason: nil)
    allow(client).to receive(:chat).and_return([content, [], usage, finish_reason])
  end

  describe "успешное сворачивание" do
    before { answer("Пользователь просил починить тесты. Поправлен spec/agent_spec.rb.") }

    it "заменяет диалог одним сообщением с резюме" do
      result = compactor.call(talk)

      expect(result.to_a.map { |m| m[:role] }).to eq(%w[system user])
      expect(result.last[:content]).to include("Поправлен spec/agent_spec.rb")
    end

    it "историю собирает заново, а не правит старую" do
      original = talk
      result = compactor.call(original)

      expect(result).not_to be(original)
      expect(original.size).to eq(3), "исходная история не должна меняться"
    end

    # Модель на просьбу подвести итог вернёт вызов инструмента, применить
    # который негде, и он потеряется молча. Тот же приём, что в Agent#summarize.
    it "запрещает инструменты в запросе резюме" do
      compactor.call(talk)

      expect(client).to have_received(:chat).with(anything, hash_including(tool_choice: "none"))
    end

    # Резюме замещает историю, а не адресовано человеку. При стриминге оно
    # печаталось в терминал целиком, и следом шёл отчёт о сворачивании —
    # найдено живой проверкой, тестами до того не ловилось.
    it "просит не показывать резюме на экране" do
      compactor.call(talk)

      expect(client).to have_received(:chat).with(anything, hash_including(visible: false))
    end

    it "отправляет модели весь диалог вместе с просьбой" do
      compactor.call(talk)

      expect(client).to have_received(:chat) do |messages, **|
        expect(messages.map { |m| m[:content] || m["content"] }.join).to include("почини тесты")
        expect(messages.last[:content]).to eq(MiniAgent::Messages::COMPACT_REQUEST)
      end
    end

    it "сообщает размер до и после" do
      compactor.call(talk)

      expect(out.string).to match(/\d+ знаков → \d+/)
    end

    # Описание проекта переживает сворачивание: новая история собирается
    # через History, а он кладёт его в системный промпт заново.
    it "сохраняет описание проекта" do
      with_context = MiniAgent::History.new(project_context: "тесты: make spec")
      compactor = described_class.new(client: client, history: with_context, ui: ui)

      result = compactor.call(talk(with_context))

      expect(result.to_a.first[:content]).to include("тесты: make spec")
    end
  end

  describe "расход токенов" do
    let(:usage) { MiniAgent::Usage.new }

    subject(:compactor) do
      described_class.new(client: client, history: history, ui: ui, usage: usage)
    end

    # Запрос сделан и оплачен. Тот же принцип, что у провалившегося хода:
    # счётчик показывает, что произошло, а не то, что осталось в истории.
    it "учитывает запрос резюме" do
      answer("резюме", usage: { "prompt_tokens" => 120, "completion_tokens" => 30 })

      compactor.call(talk)

      expect(usage.sent).to eq(120)
      expect(usage.generated).to eq(30)
    end
  end

  describe "отказы" do
    # Худший исход — потерять диалог, не получив взамен резюме. Во всех
    # ветках ниже история обязана остаться прежней и пригодной для работы.
    def expect_history_intact(original, result)
      expect(result).to be(original)
      expect(result.size).to eq(3)
    end

    it "при ошибке связи оставляет историю как была" do
      allow(client).to receive(:chat).and_raise(MiniAgent::LLMError, "сервер недоступен")
      original = talk

      expect_history_intact(original, compactor.call(original))
      expect(out.string).to include("Не удалось свернуть", "сервер недоступен")
    end

    it "при пустом резюме оставляет историю как была" do
      answer("   ")
      original = talk

      expect_history_intact(original, compactor.call(original))
      expect(out.string).to include("пустое резюме")
    end

    # Обрыв здесь опаснее, чем на обычном ходу: резюме ЗАМЕЩАЕТ историю,
    # и обрезанное на полуслове молча унесло бы часть диалога навсегда.
    it "при обрыве резюме по лимиту оставляет историю как была" do
      answer("Пользователь просил починить те", finish_reason: "length")
      original = talk

      expect_history_intact(original, compactor.call(original))
      expect(out.string).to include("Резюме оборвано")
    end

    # Обрыв съедает бюджет размышлениями и оставляет content пустым: жалоба
    # на «пустое резюме» уводила бы от причины. Найдено живой проверкой —
    # стабы этот случай пропустили, потому что задавали обрыв с текстом.
    it "при обрыве без текста называет лимит, а не пустое резюме" do
      answer("", finish_reason: "length")
      original = talk

      expect_history_intact(original, compactor.call(original))
      expect(out.string).to include("оборвано на лимите")
      expect(out.string).not_to include("пустое резюме")
    end

    it "при nil в ответе оставляет историю как была" do
      answer(nil)
      original = talk

      expect_history_intact(original, compactor.call(original))
    end

    # Interrupt не наследник StandardError: без отдельной ветки он ушёл бы
    # в Repl, где отказ от сворачивания неотличим от выхода, и Ctrl+C
    # по долгому запросу вынес бы всю сессию.
    it "по Ctrl+C оставляет историю как была и не выходит из сессии" do
      allow(client).to receive(:chat).and_raise(Interrupt)
      original = talk

      expect { expect_history_intact(original, compactor.call(original)) }.not_to raise_error
      expect(out.string).to include("прервано", "История сохранена")
    end

    # Свернуть пустой диалог значит получить ровно то же самое, но за деньги
    # и с потерей формулировок.
    it "на пустом диалоге не ходит к модели" do
      allow(client).to receive(:chat)
      empty = history.build

      expect(compactor.call(empty)).to be(empty)
      expect(client).not_to have_received(:chat)
      expect(out.string).to include("Сворачивать нечего")
    end
  end

  # Главное ограничение /compact, о котором нельзя молчать: системный промпт
  # и описание проекта возвращаются в полном объёме. Если место занято ими,
  # сворачивание не поможет — и второй раз звать его бессмысленно.
  describe "когда сворачивание не спасает" do
    it "предупреждает, что остаток занят описанием проекта" do
      answer("короткое резюме")
      # С запасом, а не впритык к признаку: при `* 200` описание перевешивало
      # на полторы сотни знаков, и пример упал от подросшего SYSTEM_PROMPT —
      # то есть проверял размер промпта, а не то, ради чего написан.
      big = MiniAgent::History.new(project_context: "описание проекта " * 600)
      compactor = described_class.new(client: client, history: big, ui: ui)

      compactor.call(talk(big))

      expect(out.string).to include("правкой файла")
    end

    # Настоящий SYSTEM_PROMPT — больше килознака и после сворачивания всегда
    # больше короткого резюме. Признак «несворачиваемое перевешивает» давал
    # бы предупреждение почти на каждом /compact, и его перестали бы читать.
    it "на обычном диалоге не предупреждает" do
      answer("резюме")

      compactor.call(talk)

      expect(out.string).not_to include("правкой файла")
    end
  end

  # Резюме с обёрткой длиннее пары реплик, которые оно заменило. Числа
  # печатаются рядом, и «свёрнут» при выросшем размере — ложь, видная тут же.
  describe "когда диалог был слишком коротким" do
    it "не рапортует о сворачивании, когда размер вырос" do
      answer("развёрнутое резюме короткого разговора " * 20)

      compactor.call(talk)

      expect(out.string).to include("слишком коротким")
      expect(out.string).not_to include("Диалог свёрнут")
    end

    it "о настоящем сворачивании рапортует" do
      long = history.build
      long.user("почини тесты " * 200)
      long.assistant("готово " * 200)
      answer("кратко: тесты починены")

      compactor.call(long)

      expect(out.string).to include("Диалог свёрнут")
    end
  end
end
