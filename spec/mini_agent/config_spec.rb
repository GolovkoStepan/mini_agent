# frozen_string_literal: true

RSpec.describe MiniAgent::Config do
  describe "приоритет источников" do
    it "берёт значение по умолчанию, когда нет ни опций, ни ENV" do
      config = described_class.new({}, env: {})

      expect(config.model).to eq("qwen/qwen3.6-35b-a3b")
      expect(config.max_turns).to eq(50)
    end

    it "предпочитает ENV значению по умолчанию" do
      config = described_class.new({}, env: { "LLM_MODEL" => "llama3" })

      expect(config.model).to eq("llama3")
    end

    it "предпочитает опции переменным окружения" do
      config = described_class.new({ model: "from-cli" }, env: { "LLM_MODEL" => "from-env" })

      expect(config.model).to eq("from-cli")
    end

    # В исходном скрипте base_url/api_key/model читались только из ENV
    # и молча игнорировали переданные опции.
    it "учитывает опции для base_url, api_key и model" do
      config = described_class.new(
        { base_url: "http://cli:9/v1", api_key: "cli-key", model: "cli-model" },
        env: { "LLM_BASE_URL" => "http://env:1/v1", "LLM_API_KEY" => "env", "LLM_MODEL" => "env" }
      )

      expect(config.base_url).to eq("http://cli:9/v1")
      expect(config.api_key).to eq("cli-key")
      expect(config.model).to eq("cli-model")
    end

    it "игнорирует пустую переменную окружения" do
      config = described_class.new({}, env: { "LLM_MODEL" => "" })

      expect(config.model).to eq("qwen/qwen3.6-35b-a3b")
    end
  end

  # Четвёртый источник: файл настроек между окружением и умолчаниями. Сам
  # файл Config не читает — его приносит CLI, поэтому здесь настройки
  # передаются готовым объектом и диск не участвует.
  describe "файл настроек" do
    def with_file(values, options = {}, env = {})
      described_class.new(options, env: env, settings: MiniAgent::Settings.new(values, path: "/tmp/s.json"))
    end

    it "перебивает умолчание" do
      expect(with_file(model: "из файла").model).to eq("из файла")
    end

    it "уступает переменной окружения" do
      expect(with_file({ model: "из файла" }, {}, { "LLM_MODEL" => "из окружения" }).model).to eq("из окружения")
    end

    it "уступает опции" do
      expect(with_file({ model: "из файла" }, { model: "из флага" }).model).to eq("из флага")
    end

    it "выключает поток значением false" do
      expect(with_file(stream: false).stream?).to be(false)
    end

    # Главная ловушка всей затеи: слив файл поверх DEFAULTS, мы получили бы
    # «max_tokens» в настройках, который молча не действует — доля окна
    # перевесила бы, потому что given? отвечает «человек этого не задавал».
    it "делает лимит токенов заданным, а не выведенным" do
      config = with_file(max_tokens: 4096)
      config.context_window = 100_000

      expect(config.max_tokens).to eq(4096)
      expect(config.max_tokens_derived?).to be(false)
    end

    # Вторая точка, зависящая от given?: политика из файла обязана перебивать
    # allow_unsafe так же, как перебивает его --policy.
    it "даёт политике из файла перебить allow_unsafe" do
      config = with_file({ policy: "ask" }, { allow_unsafe: true })

      expect(config.policy).to eq(:ask)
    end

    it "запоминает путь файла" do
      expect(with_file(model: "из файла").settings_path).to eq("/tmp/s.json")
      expect(described_class.new({}, env: {}).settings_path).to be_nil
    end
  end

  describe "#allow_unsafe?" do
    it "по умолчанию выключен" do
      expect(described_class.new({}, env: {}).allow_unsafe?).to be(false)
    end

    it "включается через ALLOW_UNSAFE=true" do
      expect(described_class.new({}, env: { "ALLOW_UNSAFE" => "true" }).allow_unsafe?).to be(true)
    end

    it "не реагирует на произвольное значение ALLOW_UNSAFE" do
      expect(described_class.new({}, env: { "ALLOW_UNSAFE" => "maybe" }).allow_unsafe?).to be(false)
    end

    # Баг исходника: options[:allow_unsafe] || ENV[...] терял явное false,
    # поэтому --no-allow-unsafe не мог перебить переменную окружения.
    it "позволяет флагу --no-allow-unsafe перебить ALLOW_UNSAFE=true" do
      config = described_class.new({ allow_unsafe: false }, env: { "ALLOW_UNSAFE" => "true" })

      expect(config.allow_unsafe?).to be(false)
    end
  end

  describe "#stream?" do
    # Включён по умолчанию: на локальной модели ответ идёт десятки секунд,
    # и неподвижный спиннер всё это время — худшее, что можно показать.
    it "по умолчанию включён" do
      expect(described_class.new({}, env: {}).stream?).to be(true)
    end

    it "выключается флагом --no-stream" do
      expect(described_class.new({ stream: false }, env: {}).stream?).to be(false)
    end

    it "выключается через LLM_STREAM=false" do
      expect(described_class.new({}, env: { "LLM_STREAM" => "false" }).stream?).to be(false)
    end

    # Флаг перебивает переменную окружения — общее правило приоритета.
    it "позволяет флагу перебить LLM_STREAM" do
      expect(described_class.new({ stream: true }, env: { "LLM_STREAM" => "false" }).stream?).to be(true)
    end
  end

  describe "#auto_compact?" do
    # Включено по умолчанию: без этого длинная задача упирается в окно и
    # обрывается там, где агент как раз работает, а /compact доступен только
    # человеку и только в интерактивном режиме.
    it "по умолчанию включено" do
      expect(described_class.new({}, env: {}).auto_compact?).to be(true)
    end

    it "выключается флагом --no-auto-compact" do
      expect(described_class.new({ auto_compact: false }, env: {}).auto_compact?).to be(false)
    end

    it "выключается через AUTO_COMPACT=false" do
      expect(described_class.new({}, env: { "AUTO_COMPACT" => "false" }).auto_compact?).to be(false)
    end

    it "позволяет флагу перебить AUTO_COMPACT" do
      config = described_class.new({ auto_compact: true }, env: { "AUTO_COMPACT" => "false" })

      expect(config.auto_compact?).to be(true)
    end
  end

  describe "#markdown?" do
    # Модель пишет markdown независимо от того, умеем ли мы его читать:
    # без разметки в тексте остаются звёздочки и решётки.
    it "по умолчанию включено" do
      expect(described_class.new({}, env: {}).markdown?).to be(true)
    end

    it "выключается флагом --no-markdown" do
      expect(described_class.new({ markdown: false }, env: {}).markdown?).to be(false)
    end

    it "выключается через AGENT_MARKDOWN=false" do
      expect(described_class.new({}, env: { "AGENT_MARKDOWN" => "false" }).markdown?).to be(false)
    end
  end

  describe "#policy" do
    it "по умолчанию deny" do
      expect(described_class.new({}, env: {}).policy).to eq(:deny)
    end

    it "читается из опции" do
      expect(described_class.new({ policy: "ask" }, env: {}).policy).to eq(:ask)
    end

    it "читается из AGENT_POLICY" do
      expect(described_class.new({}, env: { "AGENT_POLICY" => "unsafe" }).policy).to eq(:unsafe)
    end

    it "не зависит от регистра и пробелов" do
      expect(described_class.new({ policy: " ASK " }, env: {}).policy).to eq(:ask)
    end

    # Молча откатываться к умолчанию нельзя: опечатка в --policy asl означала
    # бы тихую работу с чужой политикой, а весь смысл флага — в том, какая
    # именно выбрана.
    it "падает с ConfigError на неизвестном значении" do
      expect { described_class.new({ policy: "asl" }, env: {}) }
        .to raise_error(MiniAgent::ConfigError, /asl/)
    end

    # Старый флаг остаётся рабочим: он описан в README и живёт в чужих
    # скриптах, а означает ровно одну из политик.
    it "выводится из ALLOW_UNSAFE=true" do
      expect(described_class.new({}, env: { "ALLOW_UNSAFE" => "true" }).policy).to eq(:unsafe)
    end

    it "выводится из --allow-unsafe" do
      expect(described_class.new({ allow_unsafe: true }, env: {}).policy).to eq(:unsafe)
    end

    # Из двух указаний одного смысла верим более точному.
    it "названная политика перебивает --allow-unsafe" do
      config = described_class.new({ allow_unsafe: true, policy: "ask" }, env: {})

      expect(config.policy).to eq(:ask)
      expect(config.allow_unsafe?).to be(false)
    end

    it "названная политика перебивает ALLOW_UNSAFE из окружения" do
      config = described_class.new({}, env: { "ALLOW_UNSAFE" => "true", "AGENT_POLICY" => "deny" })

      expect(config.policy).to eq(:deny)
    end

    # allow_unsafe? не отдельное поле, а вопрос к политике: два источника
    # одного решения разошлись бы при первом же несогласованном наборе флагов.
    it "согласован с allow_unsafe?" do
      expect(described_class.new({ policy: "unsafe" }, env: {}).allow_unsafe?).to be(true)
    end
  end

  # Планирование — состояние сессии, а не четвёртая политика: его включают
  # и выключают по ходу работы, тогда как политика задаётся на запуск. Флаг
  # задаёт только начальное положение.
  describe "#plan?" do
    it "выключено по умолчанию" do
      expect(described_class.new({}, env: {}).plan?).to be(false)
    end

    it "включается флагом" do
      expect(described_class.new({ plan: true }, env: {}).plan?).to be(true)
    end

    it "включается из окружения" do
      expect(described_class.new({}, env: { "AGENT_PLAN" => "true" }).plan?).to be(true)
    end
  end

  describe "#chat_uri" do
    it "собирает адрес эндпоинта из base_url" do
      config = described_class.new({ base_url: "http://localhost:1234/v1" }, env: {})

      expect(config.chat_uri.to_s).to eq("http://localhost:1234/v1/chat/completions")
    end

    it "не удваивает слеш при завершающем слеше в base_url" do
      config = described_class.new({ base_url: "http://localhost:1234/v1/" }, env: {})

      expect(config.chat_uri.to_s).to eq("http://localhost:1234/v1/chat/completions")
    end

    it "определяет ssl по схеме адреса" do
      expect(described_class.new({ base_url: "https://api.example.com/v1" }, env: {}).use_ssl?).to be(true)
      expect(described_class.new({ base_url: "http://api.example.com/v1" }, env: {}).use_ssl?).to be(false)
    end
  end

  describe "приведение типов" do
    it "приводит числовые значения из ENV к числам" do
      config = described_class.new({}, env: { "MAX_TURNS" => "42", "MAX_TOKENS" => "8192" })

      expect(config.max_turns).to eq(42)
      expect(config.max_tokens).to eq(8192)
    end
  end

  # Резерв под ответ и история делят одно окно, поэтому max_tokens нельзя
  # задать одной константой на все случаи: 4096 мало при окне 100k, а 16384
  # больше всего окна при 8192 — в живой работе /context показывал 206%
  # на пустой сессии и требовал звать /compact, которому нечего сворачивать.
  describe "максимум токенов в ответе" do
    it "берёт половину окна, когда размер известен" do
      config = described_class.new({}, env: {})
      config.context_window = 8192

      expect(config.max_tokens).to eq(4096)
    end

    # Потолок остаётся потолком: половина от 262144 — это 131072, заведомо
    # больше любого осмысленного ответа, и место у истории она бы съела зря.
    it "не превышает потолок на большом окне" do
      config = described_class.new({}, env: {})
      config.context_window = 262_144

      expect(config.max_tokens).to eq(16_384)
    end

    # Из двух указаний одного смысла верить надо более точному — тот же
    # принцип, что у --policy против --allow-unsafe.
    it "не трогает значение, заданное человеком" do
      config = described_class.new({ max_tokens: 3000 }, env: {})
      config.context_window = 8192

      expect(config.max_tokens).to eq(3000)
    end

    it "учитывает и заданное через ENV" do
      config = described_class.new({}, env: { "MAX_TOKENS" => "3000" })
      config.context_window = 8192

      expect(config.max_tokens).to eq(3000)
    end

    # Размер окна узнать не удалось — считать долю не от чего, остаётся
    # умолчание. Выдумывать окно ради этого нельзя: ошибка в бо́льшую
    # сторону хуже незнания.
    it "оставляет умолчание, когда окно неизвестно" do
      expect(described_class.new({}, env: {}).max_tokens).to eq(16_384)
    end
  end

  # От происхождения лимита зависит совет при обрыве генерации: поднимать
  # --max-tokens имеет смысл, только когда упор именно в него. При лимите,
  # выведенном из окна, флаг перепишет цифру, а обрыв придёт на том же месте.
  describe "происхождение максимума токенов" do
    it "считает лимит выведенным, когда победила доля окна" do
      config = described_class.new({}, env: {})
      config.context_window = 8192

      expect(config.max_tokens_derived?).to be(true)
    end

    # Здесь упор в потолок, а не в окно: половина от 262144 — это 131072,
    # и лимит держит константа. Поднять её флагом как раз можно.
    it "не считает выведенным лимит, упёршийся в потолок" do
      config = described_class.new({}, env: {})
      config.context_window = 262_144

      expect(config.max_tokens_derived?).to be(false)
    end

    it "не считает выведенным значение, заданное человеком" do
      config = described_class.new({ max_tokens: 3000 }, env: {})
      config.context_window = 8192

      expect(config.max_tokens_derived?).to be(false)
    end

    it "не считает выведенным умолчание при неизвестном окне" do
      expect(described_class.new({}, env: {}).max_tokens_derived?).to be(false)
    end

    # given? — общая точка для двух разных вопросов: происхождения лимита и
    # спора --policy с --allow-unsafe. Появление рядом восьми новых ключей
    # эту точку трогает, и первое, что здесь сломалось бы, — совет при обрыве
    # генерации: он молча начал бы посылать не туда.
    it "не путает соседние настройки: --temperature не меняет происхождения лимита" do
      config = described_class.new({ temperature: 0.3 }, env: {})
      config.context_window = 8192

      expect(config.max_tokens_derived?).to be(true)
    end
  end

  # Порог, с которого место считается кончившимся. Настройкой стал потому,
  # что три четверти выбраны под запас на один ход вслепую, а не под качество
  # ответов, — правильное число должны показать оценочные задачи.
  describe "#compact_at" do
    it "по умолчанию берёт порог окна" do
      expect(described_class.new({}, env: {}).compact_at).to eq(MiniAgent::Window::WARN_AT)
    end

    it "читает флаг и переменную окружения" do
      expect(described_class.new({ compact_at: "0.5" }, env: {}).compact_at).to eq(0.5)
      expect(described_class.new({}, env: { "AUTO_COMPACT_AT" => "0.4" }).compact_at).to eq(0.4)
    end

    # Проверяется, в отличие от параметров сэмплинга: там границы знает
    # сервер и он же отвергнет негодное, здесь спорить не с кем. Ноль
    # означал бы «сворачивать каждый ход», в том числе на пустой истории;
    # мусор через to_f стал бы тем же нулём молча (прецедент: --policy asl).
    it "падает на негодном значении" do
      ["abc", "0", "-0.5", "1.5", ""].each do |value|
        expect { described_class.new({ compact_at: value }, env: {}).compact_at }
          .to raise_error(MiniAgent::ConfigError, /порог сворачивания/)
      end
    end

    it "принимает единицу как крайний случай" do
      expect(described_class.new({ compact_at: "1" }, env: {}).compact_at).to eq(1.0)
    end
  end

  # Своих умолчаний у параметров сэмплинга нет: они живут на сервере.
  # Общий fetch на них падает намеренно — код, спросивший температуру
  # обычным путём, обязан ломаться громко, а не получать выдуманное число.
  describe "#given" do
    it "отдаёт заданное человеком" do
      expect(described_class.new({ temperature: 0.3 }, env: {}).given(:temperature)).to eq(0.3)
    end

    it "отдаёт nil, когда не задано ничего" do
      expect(described_class.new({}, env: {}).given(:temperature)).to be_nil
    end

    it "не теряет явное false" do
      config = described_class.new({ allow_unsafe: false }, env: { "ALLOW_UNSAFE" => "true" })

      expect(config.given(:allow_unsafe)).to be(false)
    end
  end

  # Ожидание ответа модели и таймаут команд bash — разные вещи, и держать
  # на них одно число значит, что правка ради медленной модели молча
  # продлит и зависшую команду.
  describe "ожидание ответа модели" do
    # 1200, а не 600: замер на qwen3.6-35b-a3b дал 697 секунд на просьбу
    # написать класс на 60 строк — прежнего умолчания уже не хватало.
    it "по умолчанию 1200 секунд" do
      expect(described_class.new({}, env: {}).llm_timeout).to eq(1200)
    end

    it "читается из опции и из ENV" do
      expect(described_class.new({ llm_timeout: 30 }, env: {}).llm_timeout).to eq(30)
      expect(described_class.new({}, env: { "LLM_TIMEOUT" => "45" }).llm_timeout).to eq(45)
    end

    it "не путается с таймаутом команд" do
      config = described_class.new({ llm_timeout: 300 }, env: { "COMMAND_TIMEOUT" => "10" })

      expect(config.llm_timeout).to eq(300)
      expect(config.timeout).to eq(10)
    end
  end

  describe "контекстное окно" do
    it "по умолчанию неизвестно" do
      expect(described_class.new({}, env: {}).context_window).to be_nil
    end

    it "читается из опции и из ENV" do
      expect(described_class.new({ context_window: 65_536 }, env: {}).context_window).to eq(65_536)
      expect(described_class.new({}, env: { "CONTEXT_WINDOW" => "8192" }).context_window).to eq(8192)
    end

    # Ноль и мусор означают то же, что и отсутствие значения. Превратить их
    # в 0 значило бы сделать «неизвестно» неотличимым от «окно нулевого
    # размера», и всё, что считает доли от окна, делило бы на ноль.
    it "не принимает ноль и мусор за размер" do
      expect(described_class.new({ context_window: 0 }, env: {}).context_window).to be_nil
      expect(described_class.new({}, env: { "CONTEXT_WINDOW" => "мусор" }).context_window).to be_nil
    end

    # Записываемо: значение приходит от сервера уже после создания настроек.
    it "принимает узнанное у сервера значение" do
      config = described_class.new({}, env: {})
      config.context_window = 8192

      expect(config.context_window).to eq(8192)
    end
  end

  describe "рабочий каталог" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    it "по умолчанию не задан" do
      expect(described_class.new({}, env: {}).cwd).to be_nil
    end

    it "разворачивает относительный путь в абсолютный" do
      config = described_class.new({ cwd: @dir }, env: {})

      expect(config.cwd).to eq(File.expand_path(@dir))
    end

    it "читается из AGENT_CWD" do
      config = described_class.new({}, env: { "AGENT_CWD" => @dir })

      expect(config.cwd).to eq(File.expand_path(@dir))
    end

    # Иначе опечатка в пути всплывёт посреди работы невнятной ошибкой Open3,
    # уже после запроса к модели.
    it "падает сразу, если каталога нет" do
      expect { described_class.new({ cwd: "/нет/такого/каталога" }, env: {}) }
        .to raise_error(MiniAgent::ConfigError, /Рабочий каталог не найден/)
    end

    it "падает, если путь ведёт на файл" do
      path = File.join(@dir, "файл.txt")
      File.write(path, "не каталог")

      expect { described_class.new({ cwd: path }, env: {}) }.to raise_error(MiniAgent::ConfigError)
    end

    it "пустое значение равносильно отсутствию" do
      expect(described_class.new({}, env: { "AGENT_CWD" => "" }).cwd).to be_nil
    end
  end

  describe "журнал" do
    around do |example|
      Dir.mktmpdir { |dir| example.run(@dir = dir) }
    end

    # В журнал уходят и задачи, и содержимое всего, что агент прочитал.
    # Включать такое молча нельзя.
    it "по умолчанию выключен" do
      expect(described_class.new({}, env: {}).log).to be_nil
    end

    it "разворачивает путь в абсолютный" do
      config = described_class.new({ log: File.join(@dir, "session.jsonl") }, env: {})

      expect(config.log).to eq(File.join(File.expand_path(@dir), "session.jsonl"))
    end

    it "читается из AGENT_LOG" do
      config = described_class.new({}, env: { "AGENT_LOG" => File.join(@dir, "s.jsonl") })

      expect(config.log).to end_with("s.jsonl")
    end

    # Файла ещё нет — это норма, а вот каталога быть обязан.
    it "не требует существования самого файла" do
      expect { described_class.new({ log: File.join(@dir, "нового.jsonl") }, env: {}) }.not_to raise_error
    end

    it "падает сразу, если каталога нет" do
      expect { described_class.new({ log: "/нет/такого/каталога/s.jsonl" }, env: {}) }
        .to raise_error(MiniAgent::ConfigError, /Каталог для журнала не найден/)
    end

    it "пустое значение равносильно отсутствию" do
      expect(described_class.new({}, env: { "AGENT_LOG" => "" }).log).to be_nil
    end
  end
end
