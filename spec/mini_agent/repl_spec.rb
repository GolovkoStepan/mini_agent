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

    # Версия печатается в приветствии, потому что в интерактивном режиме
    # проводится всё время, а --version там уже не набрать.
    it "называет версию в приветствии" do
      allow(client).to receive(:chat).and_return(["ответ", []])

      repl("exit\n").run

      expect(out.string).to include("Mini Agent v#{MiniAgent::VERSION} (интерактивный режим)")
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

    # Историю подменяют не только команды: обычная задача тоже отдаёт новую,
    # если по ходу сработало автоматическое сворачивание. Прежде здесь стояло
    # `@agent.run(...); conversation`, и свёрнутое терялось на следующей же
    # задаче — молча, потому что работа продолжалась как ни в чём не бывало.
    it "продолжает работу со свёрнутой историей, а не с прежней" do
      folded = MiniAgent::History.new.build.tap { |c| c.user("Резюме диалога.") }
      auto = instance_double(MiniAgent::AutoCompactor)
      allow(auto).to receive(:call).and_return(folded)
      allow(client).to receive(:chat).and_return(["ответ", []])
      agent = MiniAgent::Agent.new(
        config: config, client: client, tools: tools, ui: ui, auto_compactor: auto
      )
      reader = MiniAgent::LineReader.new(input: StringIO.new("задача\nexit\n"), output: out)

      conversation = described_class.new(
        agent: agent, config: config, tools: tools, ui: ui, reader: reader
      ).run

      expect(conversation).to be(folded)
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

    describe "/context" do
      it "показывает разбивку по накопленной истории" do
        allow(client).to receive(:chat).and_return(["ответ", []])

        repl("задача\n/context\nexit\n").run

        expect(out.string).to include("Контекст:", "системный промпт", "задачи")
      end

      it "не ходит к модели" do
        allow(client).to receive(:chat)

        repl("/context\nexit\n").run

        expect(client).not_to have_received(:chat)
      end
    end

    describe "/init" do
      # Новое описание применяется при следующей сборке истории, а не сразу:
      # проверяем именно связку /init → /clear, потому что молчаливая потеря
      # описания на очистке — та самая ошибка, ради которой заведена History.
      it "описание попадает в историю после /clear" do
        Dir.mktmpdir do |dir|
          config = MiniAgent::Config.new({ max_turns: 3, cwd: dir }, env: {})
          agent = MiniAgent::Agent.new(
            config: config, client: client, tools: tools, ui: ui,
            prompt: MiniAgent::Prompt::AutoApprove.new
          )
          allow(client).to receive(:chat) do
            File.write(File.join(dir, "AGENTS.md"), "Тесты: make spec")
            ["записал", []]
          end

          reader = MiniAgent::LineReader.new(input: StringIO.new("/init\n/clear\nexit\n"), output: out)
          conversation = described_class.new(
            agent: agent, config: config, tools: tools, ui: ui, reader: reader
          ).run

          expect(conversation.to_a.first[:content]).to include("make spec")
        end
      end
    end

    describe "/plan" do
      # Тот же объект, что у охраны команд: свой у Repl означал бы включённый
      # режим, о котором CommandGuard не знает, — то есть план, по ходу
      # которого агент правит файлы.
      def planning_repl(input, prompt: MiniAgent::Prompt::AutoDeny.new)
        agent = MiniAgent::Agent.new(config: config, client: client, tools: tools, ui: ui, prompt: prompt)
        reader = MiniAgent::LineReader.new(input: StringIO.new(input), output: out)
        [agent, described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader)]
      end

      it "переключает режим туда и обратно" do
        agent, repl = planning_repl("/plan\n/plan\nexit\n")
        repl.run

        expect(agent.plan_mode.on?).to be(false)
        expect(out.string).to include("Режим планирования включён", "Режим планирования выключен")
      end

      # Главное про эту ветку: включённый режим меняет обработку обычной
      # задачи. Без ветвления в run_task задача шла бы прямо в Agent#run,
      # то есть выполнялась бы вместо планирования — и заметить это можно
      # было бы только по изменённым файлам.
      it "проводит задачу через планирование и спрашивает, выполнять ли" do
        allow(client).to receive(:chat).and_return(["1. Прочитать. 2. Написать.", []])
        prompt = instance_spy(MiniAgent::Prompt, ask: "n")
        agent, repl = planning_repl("/plan\nкак добавить X?\nexit\n", prompt: prompt)
        repl.run

        expect(prompt).to have_received(:ask).with(/Выполнять этот план/)
        expect(agent.plan_mode.plan).to eq("1. Прочитать. 2. Написать.")
      end

      # Инструкция режима идёт отдельным сообщением перед задачей: системный
      # промпт собран на старте, а /plan набирают посреди сессии.
      it "предупреждает модель о запрете правок" do
        allow(client).to receive(:chat).and_return(["план", []])
        _, repl = planning_repl("/plan\nкак добавить X?\nexit\n")
        conversation = repl.run

        expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user user assistant])
        expect(conversation.to_a[1][:content]).to include("Planning mode is on")
      end

      # /init пишет файл — то самое, чего режим не делает. Отказ стоит до
      # запуска, а не приходит отказом инструмента: иначе агент потратил бы
      # полдюжины ходов на изучение проекта и не смог бы записать результат.
      it "не даёт запустить /init во время планирования" do
        allow(client).to receive(:chat).and_return(["ответ", []])
        _, repl = planning_repl("/plan\n/init\nexit\n")
        repl.run

        expect(client).not_to have_received(:chat)
        expect(out.string).to include("/init пишет файл")
      end
    end

    describe "/compact" do
      # Главное про эту ветку: свёрнутая история должна уехать в следующую
      # итерацию цикла. Вернуть здесь прежнюю conversation — значит молча
      # продолжить со старой историей, и снаружи это выглядело бы работающим.
      it "заменяет историю резюме и продолжает с ней" do
        allow(client).to receive(:chat).and_return(
          ["первый ответ", []], ["резюме диалога", []], ["второй ответ", []]
        )

        conversation = repl("задача 1\n/compact\nзадача 2\nexit\n").run

        expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user user assistant])
        expect(conversation.to_a[1][:content]).to include("резюме диалога")
      end

      # Отказ сворачивания — не отказ сессии: работать можно дальше
      # с той историей, что была.
      it "при ошибке оставляет прежнюю историю и не выходит" do
        responses = [
          -> { ["первый ответ", []] },
          -> { raise MiniAgent::LLMError, "сервер недоступен" },
          -> { ["второй ответ", []] }
        ]
        allow(client).to receive(:chat) { responses.shift.call }

        conversation = repl("задача 1\n/compact\nзадача 2\nexit\n").run

        expect(out.string).to include("Не удалось свернуть", "второй ответ")
        expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant user assistant])
      end

      # /compact собирает историю заново — тем же путём, что и /clear,
      # и с теми же граблями: описание проекта и журнал должны уехать в неё.
      it "сохраняет описание проекта и журнал" do
        allow(client).to receive(:chat).and_return(["ответ", []], ["резюме", []])
        transcript = instance_spy(MiniAgent::Transcript)
        agent = MiniAgent::Agent.new(
          config: config, client: client, tools: tools, ui: ui,
          history: MiniAgent::History.new(project_context: "тесты: make spec", transcript: transcript)
        )
        reader = MiniAgent::LineReader.new(input: StringIO.new("задача\n/compact\nexit\n"), output: out)

        conversation = described_class.new(agent: agent, config: config, tools: tools, ui: ui, reader: reader).run

        expect(conversation.to_a.first[:content]).to include("тесты: make spec")
        expect(transcript).to have_received(:compact).with(hash_including(:before))
      end
    end

    # Раньше упавшая задача оставляла в истории сообщение без ответа, и на
    # переполненном контексте следующая падала тем же образом — сессия
    # оставалась мёртвой до /clear. Теперь работать можно дальше.
    it "продолжает сессию после неудачной задачи" do
      responses = [-> { raise MiniAgent::LLMError, "переполнен контекст" }, -> { ["готово", []] }]
      allow(client).to receive(:chat) { responses.shift.call }

      conversation = repl("упавшая задача\nследующая задача\nexit\n").run

      expect(out.string).to include("готово")
      expect(conversation.to_a.map { |m| m[:role] }).to eq(%w[system user assistant])
    end
  end
end
