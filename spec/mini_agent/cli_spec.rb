# frozen_string_literal: true

RSpec.describe MiniAgent::CLI do
  let(:out) { StringIO.new }
  # Проба размера окна идёт при каждом старте агента, и адрес сервера в
  # примерах ниже разный — отсюда образец вместо точного URL. По умолчанию
  # отвечаем отказом: так ведёт себя любой сервер, кроме LM Studio, и все
  # примеры заодно проверяют, что без пробы агент работает как прежде.
  before { stub_request(:get, %r{/api/v0/models}).to_return(status: 404, body: "") }

  def start(argv, input: StringIO.new(""))
    described_class.start(argv, out: out, input: input)
  end

  # Ответ в том виде, в каком его получает пользователь: стриминг включён
  # по умолчанию, и стаб с обычным JSON проверял бы путь, которым никто
  # не ходит. Тесты самого разбора потока — в llm_client_spec.
  def sse(content, finish_reason: "stop")
    event = { "choices" => [{ "index" => 0, "delta" => { "content" => content },
                              "finish_reason" => finish_reason }] }
    "data: #{event.to_json}\n\ndata: [DONE]\n\n"
  end

  describe "справка и версия" do
    it "печатает справку по --help с кодом 0" do
      expect(start(["--help"])).to eq(0)
      expect(out.string).to include("Использование: mini_agent")
    end

    it "печатает справку по -h" do
      expect(start(["-h"])).to eq(0)
      expect(out.string).to include("--interactive")
    end

    it "печатает версию по --version" do
      expect(start(["--version"])).to eq(0)
      expect(out.string.strip).to eq(MiniAgent::VERSION)
    end

    it "перечисляет все опции в справке" do
      start(["--help"])

      %w[--max-turns --retry-count --retry-delay --base-url --model --[no-]allow-unsafe].each do |flag|
        expect(out.string).to include(flag)
      end
    end
  end

  describe "запуск без задачи" do
    it "возвращает код 1 и подсказку" do
      expect(start([])).to eq(1)
      expect(out.string).to include("Не указана задача")
    end

    it "возвращает код 1 при пустой строке задачи" do
      expect(start(["   "])).to eq(1)
    end
  end

  describe "разбор опций" do
    it "сообщает о неизвестной опции с кодом 1" do
      expect(start(["--unknown-flag"])).to eq(1)
      expect(out.string).to include("invalid option")
    end

    it "сообщает о некорректном значении числовой опции" do
      expect(start(["--max-turns", "не-число", "задача"])).to eq(1)
      expect(out.string).to include("invalid argument")
    end
  end

  describe "запуск задачи" do
    let(:endpoint) { "http://cli.test/v1/chat/completions" }

    before do
      stub_request(:post, endpoint).to_return(status: 200, body: sse("готово"))
    end

    it "выполняет задачу и возвращает код 0" do
      code = start(["--base-url", "http://cli.test/v1", "посчитай файлы"])

      expect(code).to eq(0)
      expect(out.string).to include("готово")
    end

    it "склеивает несколько аргументов в одну задачу" do
      start(["--base-url", "http://cli.test/v1", "посчитай", "файлы", "в", "проекте"])

      matcher = a_request(:post, endpoint)
                .with { |req| JSON.parse(req.body)["messages"].last["content"] == "посчитай файлы в проекте" }
      expect(matcher).to have_been_made
    end

    it "передаёт модель из --model" do
      start(["--base-url", "http://cli.test/v1", "--model", "llama3", "задача"])

      expect(a_request(:post, endpoint).with(body: hash_including("model" => "llama3"))).to have_been_made
    end

    it "передаёт схему инструмента bash" do
      start(["--base-url", "http://cli.test/v1", "задача"])

      matcher = a_request(:post, endpoint)
                .with { |req| JSON.parse(req.body)["tools"].first["function"]["name"] == "bash" }
      expect(matcher).to have_been_made
    end

    describe "--cwd" do
      around do |example|
        Dir.mktmpdir { |dir| example.run(@dir = dir) }
      end

      it "передаёт каталог в исполнитель команд" do
        allow(MiniAgent::ProcessRunner).to receive(:new).and_call_original

        start(["--base-url", "http://cli.test/v1", "--cwd", @dir, "задача"])

        expect(MiniAgent::ProcessRunner)
          .to have_received(:new).with(hash_including(cwd: File.expand_path(@dir)))
      end

      # Читать описание одного проекта, работая в другом, — худшее из
      # возможных поведений.
      it "ищет описание проекта в рабочем каталоге, а не в каталоге запуска" do
        File.write(File.join(@dir, "AGENTS.md"), "Описание из --cwd")

        start(["--base-url", "http://cli.test/v1", "--cwd", @dir, "задача"])

        matcher = a_request(:post, endpoint)
                  .with { |req| JSON.parse(req.body)["messages"].first["content"].include?("Описание из --cwd") }
        expect(matcher).to have_been_made
      end

      # Ошибка употребления, а не сбой связи: код 1, а не 2.
      it "сообщает о несуществующем каталоге с кодом 1" do
        code = start(["--base-url", "http://cli.test/v1", "--cwd", "/нет/такого", "задача"])

        expect(code).to eq(1)
        expect(out.string).to include("Рабочий каталог не найден")
      end
    end

    describe "--log" do
      around do |example|
        Dir.mktmpdir { |dir| example.run(@dir = dir) }
      end

      def log_path = File.join(@dir, "session.jsonl")

      def records = File.readlines(log_path).map { |line| JSON.parse(line) }

      it "пишет заголовок сессии и все сообщения диалога" do
        start(["--base-url", "http://cli.test/v1", "--log", log_path, "посчитай файлы"])

        expect(records.map { |r| r["type"] }).to eq(%w[session message message message])
        expect(records.map { |r| r["role"] }).to eq([nil, "system", "user", "assistant"])
      end

      it "сохраняет текст задачи и ответ модели" do
        start(["--base-url", "http://cli.test/v1", "--log", log_path, "посчитай файлы"])

        contents = records.map { |r| r["content"] }
        expect(contents).to include("посчитай файлы")
        expect(contents).to include("готово")
      end

      # Молчаливая запись задач и содержимого прочитанных файлов — не то,
      # о чём стоит умалчивать.
      it "сообщает о включённом журнале" do
        start(["--base-url", "http://cli.test/v1", "--log", log_path, "задача"])

        expect(out.string).to include("Журнал: #{log_path}")
      end

      it "без опции файл не создаётся" do
        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(File.exist?(log_path)).to be(false)
      end

      # Ошибка употребления, а не сбой связи: код 1, а не 2.
      it "сообщает о несуществующем каталоге с кодом 1" do
        code = start(["--base-url", "http://cli.test/v1", "--log", "/нет/такого/s.jsonl", "задача"])

        expect(code).to eq(1)
        expect(out.string).to include("Каталог для журнала не найден")
      end
    end

    # Размер контекстного окна протокол не сообщает, а знать его надо: в него
    # упирается и рост истории, и max_tokens. У LM Studio он есть в своём
    # /api/v0/models — оттуда и берём, когда получается.
    describe "размер контекстного окна" do
      def loaded(size)
        { "data" => [{ "id" => "qwen", "state" => "loaded", "loaded_context_length" => size }] }.to_json
      end

      it "спрашивает сервер при старте" do
        stub_request(:get, %r{/api/v0/models}).to_return(status: 200, body: loaded(65_536))

        start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new("/model\nexit\n"))

        expect(out.string).to include("65536 токенов")
      end

      # Заданное человеком перебивает угаданное, и лишний запрос при старте
      # только задержал бы его.
      it "не спрашивает, когда размер задан явно" do
        start(["-i", "--base-url", "http://cli.test/v1", "--context-window", "4096"],
              input: StringIO.new("/model\nexit\n"))

        expect(out.string).to include("4096 токенов")
        expect(a_request(:get, %r{/api/v0/models})).not_to have_been_made
      end

      # Так ответит любой сервер, кроме LM Studio. Проба необязательна, и
      # её неудача не должна ни мешать работе, ни шуметь в выводе.
      it "молчит и работает дальше, когда сервер не отвечает на пробу" do
        code = start(["--base-url", "http://cli.test/v1", "задача"])

        expect(code).to eq(0)
        expect(out.string).to include("готово")
      end
    end

    # Сервер ответил отказом: соединение открылось, но задача не сделана.
    # Живой случай — HTTP 400 «превышен размер контекста»: агент печатал
    # ошибку и выходил с нулём, и обёртка считала задачу выполненной.
    describe "провал запроса к модели" do
      before do
        stub_request(:post, endpoint).to_return(
          status: 400,
          body: { "error" => { "message" => "request exceeds the available context size" } }.to_json
        )
      end

      it "возвращает код 3, а не 0" do
        code = start(["--base-url", "http://cli.test/v1", "задача"])

        expect(code).to eq(3)
      end

      it "печатает причину отказа" do
        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(out.string).to include("context size")
      end

      # Код 2 закреплён за «сервера нет вовсе» — эти случаи не сливаются.
      it "не путается с кодом недоступного сервера" do
        expect(MiniAgent::CLI::EXIT_LLM).not_to eq(MiniAgent::CLI::EXIT_CONNECT)
      end
    end

    # Ходы кончились раньше задачи. Всё работало исправно, но сделана она
    # наполовину: агент возвращал 0 и обёртка считала её успешной.
    describe "исчерпанные ходы" do
      before do
        body = {
          "choices" => [{
            "message" => {
              "content" => "работаю",
              "tool_calls" => [{ "id" => "c1", "type" => "function",
                                 "function" => { "name" => "bash",
                                                 "arguments" => { "command" => "echo привет" }.to_json } }]
            },
            "finish_reason" => "tool_calls"
          }]
        }
        stub_request(:post, endpoint).to_return(
          status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" }
        )
      end

      it "возвращает код 4" do
        code = start(["--base-url", "http://cli.test/v1", "--no-stream", "--max-turns", "1", "задача"])

        expect(code).to eq(4)
        expect(out.string).to include("задача может быть не доделана")
      end

      # Лечение разное: там сеть или модель, здесь --max-turns. Слив кодов
      # означал бы, что обёртка одинаково реагирует на два разных сбоя.
      it "не путается с кодом провалившегося запроса" do
        expect(MiniAgent::CLI::EXIT_UNFINISHED).not_to eq(MiniAgent::CLI::EXIT_LLM)
      end
    end

    describe "контекст проекта" do
      it "подмешивает описание проекта в системный промпт" do
        allow(MiniAgent::ProjectContext).to receive(:new).and_return(
          instance_double(MiniAgent::ProjectContext, load: "Тесты: make spec", filename: "AGENTS.md",
                                                     truncated?: false)
        )

        start(["--base-url", "http://cli.test/v1", "задача"])

        matcher = a_request(:post, endpoint)
                  .with { |req| JSON.parse(req.body)["messages"].first["content"].include?("Тесты: make spec") }
        expect(matcher).to have_been_made
      end

      # Молчаливое изменение поведения агента хуже лишней строки в выводе.
      it "сообщает, что контекст подхвачен" do
        allow(MiniAgent::ProjectContext).to receive(:new).and_return(
          instance_double(MiniAgent::ProjectContext, load: "описание", filename: "AGENTS.md",
                                                     truncated?: false)
        )

        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(out.string).to include("Контекст проекта: AGENTS.md")
      end

      # Урезанное описание — потеря знаний о проекте, которую по поведению
      # агента не увидеть: он просто не упомянет того, чего не читал.
      # Лечение неочевидно и потому названо в той же строке.
      it "предупреждает, что описание не влезло в окно" do
        allow(MiniAgent::ProjectContext).to receive(:new).and_return(
          instance_double(MiniAgent::ProjectContext, load: "описание", filename: "AGENTS.md",
                                                     truncated?: true, kept: 5120, total: 80_000,
                                                     limited_by: :window)
        )

        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(out.string).to include("урезано до 5120 из 80000 знаков")
        expect(out.string).to include("бо́льшим окном")
      end

      # Причин обрезки две, и лечения у них противоположны по адресу: там
      # сервер, здесь файл. Живая проверка при окне 60416 показала, как одно
      # сообщение на оба случая посылает чинить сервер вместо файла.
      it "не винит окно, когда описание урезал потолок" do
        allow(MiniAgent::ProjectContext).to receive(:new).and_return(
          instance_double(MiniAgent::ProjectContext, load: "описание", filename: "AGENTS.md",
                                                     truncated?: true, kept: 19_936, total: 89_600,
                                                     limited_by: :ceiling)
        )

        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(out.string).to include("урезано до 19936 из 89600 знаков")
        expect(out.string).to include("Помогает только правка файла")
        expect(out.string).not_to include("бо́льшим окном")
      end

      it "молчит, когда описания нет" do
        allow(MiniAgent::ProjectContext).to receive(:new).and_return(
          instance_double(MiniAgent::ProjectContext, load: nil, filename: nil)
        )

        start(["--base-url", "http://cli.test/v1", "задача"])

        expect(out.string).not_to include("Контекст проекта")
      end
    end
  end

  # Соединение открывается в LLMClient#start, до первого запроса, поэтому
  # webmock здесь не подходит: он перехватывает запросы, а не установку
  # соединения. Подменяем сам start.
  describe "--list-models" do
    let(:models_endpoint) { "http://cli.test/v1/models" }

    def models_response(*names)
      { "data" => names.map { |name| { "id" => name, "object" => "model" } } }.to_json
    end

    def list_models(*extra)
      start(["--list-models", "--base-url", "http://cli.test/v1", *extra])
    end

    it "печатает загруженные модели" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: models_response("qwen", "deepseek"))

      expect(list_models).to eq(0)
      expect(out.string).to include("qwen")
      expect(out.string).to include("deepseek")
    end

    it "показывает адрес сервера в заголовке" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: models_response("qwen"))

      list_models

      expect(out.string).to include("Модели на http://cli.test/v1:")
    end

    # Ради этого сравнения команду и запускают: умолчание модели совпадает
    # с загруженной далеко не всегда.
    it "помечает выбранную модель звёздочкой" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: models_response("qwen", "deepseek"))

      list_models("--model", "deepseek")

      expect(out.string).to include("  * deepseek")
      expect(out.string).to include("    qwen")
    end

    it "сортирует имена" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: models_response("яблоко", "deepseek", "qwen"))

      list_models

      expect(out.string.lines.map(&:strip).reject(&:empty?).drop(1)).to eq(%w[deepseek qwen яблоко])
    end

    it "сообщает о пустом списке вместо голого заголовка" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: { "data" => [] }.to_json)

      expect(list_models).to eq(0)
      expect(out.string).to include("не загружено ни одной модели")
    end

    it "не запускает агента" do
      stub_request(:get, models_endpoint).to_return(status: 200, body: models_response("qwen"))

      list_models

      expect(a_request(:post, "http://cli.test/v1/chat/completions")).not_to have_been_made
    end

    it "сообщает об ошибке сервера с кодом 2" do
      stub_request(:get, models_endpoint).to_return(status: 500, body: "boom")

      expect(list_models).to eq(2)
      expect(out.string).to include("500")
    end

    # LM Studio отвечает 200 с полем error в теле, когда путь не тот
    # (например, base_url без /v1). Сообщение «поле data отсутствует»
    # формально верно и совершенно бесполезно.
    it "показывает причину, когда сервер вернул ошибку в теле с кодом 200" do
      body = { "error" => "Unexpected endpoint or method. (GET /nope/models)" }.to_json
      stub_request(:get, models_endpoint).to_return(status: 200, body: body)

      expect(list_models).to eq(2)
      expect(out.string).to include("Unexpected endpoint")
    end

    it "сообщает о недоступном сервере вместо бэктрейса" do
      stub_request(:get, models_endpoint).to_raise(Errno::ECONNREFUSED)

      expect(list_models).to eq(2)
      expect(out.string).to include("Не удалось подключиться")
    end
  end

  describe "недоступный LLM" do
    def fail_connection_with(error)
      allow_any_instance_of(MiniAgent::LLMClient).to receive(:start).and_raise(error)
    end

    it "сообщает адрес и способ его сменить вместо бэктрейса" do
      fail_connection_with(Net::OpenTimeout.new("Failed to open TCP connection to 10.0.0.1:1234"))

      code = start(["--base-url", "http://10.0.0.1:1234/v1", "задача"])

      expect(code).to eq(2)
      expect(out.string).to include("Не удалось подключиться к LLM: http://10.0.0.1:1234/v1")
      expect(out.string).to include("Failed to open TCP connection")
      expect(out.string).to include("--base-url")
    end

    it "обрабатывает отказ в соединении" do
      fail_connection_with(Errno::ECONNREFUSED)

      expect(start(["--base-url", "http://127.0.0.1:1/v1", "задача"])).to eq(2)
      expect(out.string).to include("Не удалось подключиться")
    end

    # Тот же путь в интерактивном режиме: агент не стартовал, приглашения нет.
    it "не открывает диалог, если соединение не поднялось" do
      fail_connection_with(Errno::ECONNREFUSED)

      code = start(["-i", "--base-url", "http://127.0.0.1:1/v1"], input: StringIO.new("задача\nexit\n"))

      expect(code).to eq(2)
      expect(out.string).to include("Не удалось подключиться")
      expect(out.string).not_to include("До свидания!")
    end

    # Совет «проверьте, что сервер запущен» здесь был бы ложным следом.
    it "отдельно сообщает о некорректном адресе" do
      fail_connection_with(URI::InvalidURIError)

      code = start(["--base-url", "http://[кривой", "задача"])

      expect(code).to eq(2)
      expect(out.string).to include("Некорректный адрес LLM")
      expect(out.string).not_to include("сервер запущен")
    end
  end

  describe "интерактивный режим" do
    it "запускается и завершается по exit" do
      stub_request(:post, "http://cli.test/v1/chat/completions").to_return(status: 200, body: sse("ответ"))

      code = start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new("задача\nexit\n"))

      expect(code).to eq(0)
      expect(out.string).to include("интерактивный режим")
      expect(out.string).to include("До свидания!")
    end

    it "завершается сразу при пустом вводе" do
      expect(start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new(""))).to eq(0)
    end

    # Провал одной задачи — не провал сессии: пользователь ошибку увидел,
    # мог уточнить задачу и продолжить, а код относится ко всему сеансу.
    it "остаётся нулём даже после неудачной задачи" do
      stub_request(:post, "http://cli.test/v1/chat/completions").to_return(status: 400, body: "{}")

      code = start(["-i", "--base-url", "http://cli.test/v1"], input: StringIO.new("задача\nexit\n"))

      expect(code).to eq(0)
    end
  end
end
