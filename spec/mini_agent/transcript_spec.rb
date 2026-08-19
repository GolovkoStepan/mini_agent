# frozen_string_literal: true

require "tmpdir"
require "json"

RSpec.describe MiniAgent::Transcript do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:path) { File.join(@dir, "session.jsonl") }
  let(:out) { StringIO.new }
  let(:ui) { MiniAgent::UI.new(out: out, tty: false) }

  def records
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  describe "запись" do
    it "пишет по объекту JSON на строку" do
      log = described_class.new(path)
      log.message({ role: "user", content: "задача" })
      log.message({ role: "assistant", content: "ответ" })
      log.close

      expect(records.map { |r| r["role"] }).to eq(%w[user assistant])
      expect(records.first).to include("type" => "message", "content" => "задача")
    end

    it "проставляет время каждой записи" do
      clock = double(now: Time.at(0).utc)
      log = described_class.new(path, clock: clock)
      log.message({ role: "user", content: "задача" })
      log.close

      expect(records.first["time"]).to eq("1970-01-01T00:00:00Z")
    end

    # Дописывание, а не перезапись: несколько запусков с одним --log должны
    # складываться в один файл, иначе прошлый прогон теряется ровно тогда,
    # когда его и хотели сравнить с новым.
    it "дописывает файл, а не перезаписывает" do
      described_class.new(path).tap { |log| log.message({ role: "user", content: "первый" }) }.close
      described_class.new(path).tap { |log| log.message({ role: "user", content: "второй" }) }.close

      expect(records.map { |r| r["content"] }).to eq(%w[первый второй])
    end
  end

  describe "заголовок сессии" do
    it "пишет модель, сервер и каталог" do
      config = MiniAgent::Config.new({ model: "test-model", base_url: "http://example:1234/v1" }, env: {})
      log = described_class.new(path)
      log.session(config)
      log.close

      expect(records.first).to include("type" => "session", "model" => "test-model")
      expect(records.first["base_url"]).to eq("http://example:1234/v1")
    end

    # Журнал переживает сессию и разбирается спустя недели, а поведение агента
    # между версиями меняется: без этого поля по старому логу не сказать, по
    # какому расчёту в нём выведен max_tokens.
    it "пишет версию агента" do
      log = described_class.new(path)
      log.session(MiniAgent::Config.new({}, env: {}))
      log.close

      expect(records.first["version"]).to eq(MiniAgent::VERSION)
    end

    # Лог заводят, чтобы показать его кому-то ещё; ключ в нём — утечка,
    # которую никто не заметит.
    it "не пишет api_key" do
      config = MiniAgent::Config.new({ api_key: "секретный-ключ" }, env: {})
      log = described_class.new(path)
      log.session(config)
      log.close

      expect(File.read(path)).not_to include("секретный-ключ")
    end

    # По журналу сравнивают прогоны между собой, а сэмплинг определяет, как
    # модель отвечает: без него два лога с разными настройками выглядят
    # одинаково.
    it "пишет параметры сэмплинга" do
      config = MiniAgent::Config.new({ temperature: 0.3, top_k: 50 }, env: {})
      log = described_class.new(path)
      log.session(config)
      log.close

      expect(records.first["sampling"]).to eq({ "temperature" => 0.3, "top_k" => 50 })
    end

    # Пустой объект, а не отсутствие ключа: без записи «ничего не задавали»
    # неотличимо от журнала, снятого версией агента, которая о сэмплинге
    # ещё не знала, — а это и есть та разница, ради которой поле заведено.
    it "пишет пустой сэмплинг, когда не задано ничего" do
      log = described_class.new(path)
      log.session(MiniAgent::Config.new({}, env: {}))
      log.close

      expect(records.first["sampling"]).to eq({})
    end
  end

  describe "устойчивость" do
    # Данные пишутся по мере появления: разбираться в логе приходится как раз
    # тогда, когда до close дело не дошло.
    it "оставляет записи на диске до закрытия файла" do
      log = described_class.new(path)
      log.message({ role: "user", content: "задача" })

      expect(records.size).to eq(1)
      log.close
    end

    it "молчит после закрытия, а не падает на закрытом файле" do
      log = described_class.new(path, ui: ui)
      log.close

      expect { log.message({ role: "user", content: "задача" }) }.not_to raise_error
      expect(out.string).to be_empty
    end

    it "сообщает о сбое и прекращает запись" do
      log = described_class.new(path, ui: ui)
      # Сообщение, которое JSON сериализовать не может.
      log.message({ role: "user", content: "\xFF".dup.force_encoding("UTF-8") })
      log.message({ role: "user", content: "после сбоя" })

      expect(out.string).to include("Запись в журнал прекращена")
      expect(out.string.scan("Запись в журнал прекращена").size).to eq(1)
      expect(records).to be_empty
    end

    it "объясняет, почему файл не открылся" do
      expect { described_class.new(File.join(@dir, "нет", "session.jsonl")) }
        .to raise_error(MiniAgent::ConfigError, /Не удалось открыть журнал/)
    end
  end

  # Ход, снятый с истории, из журнала не вычёркивается: он протоколирует то,
  # что действительно уходило модели. Иначе по логу нельзя было бы понять,
  # на каком именно сообщении запрос упал.
  describe "откат хода" do
    it "отмечает откат отдельной записью, сохраняя снятые сообщения" do
      log = described_class.new(path)
      log.message({ role: "user", content: "упавшая задача" })
      log.rollback(1)
      log.close

      expect(records.map { |r| r["type"] }).to eq(%w[message rollback])
      expect(records.first["content"]).to eq("упавшая задача")
      expect(records.last["removed"]).to eq(1)
    end
  end

  # Как и при откате: свёрнутые сообщения из файла не вычёркиваются — они
  # действительно уходили модели. Без отметки лог выглядел бы так, будто
  # модель ни с того ни с сего получила пересказ собственного разговора.
  describe "сворачивание диалога" do
    it "отмечает сворачивание, сохраняя свёрнутые сообщения" do
      log = described_class.new(path)
      log.message({ role: "user", content: "почини тесты" })
      log.compact(before: 1500)
      log.message({ role: "user", content: "<conversation_summary>…" })
      log.close

      expect(records.map { |r| r["type"] }).to eq(%w[message compact message])
      expect(records.first["content"]).to eq("почини тесты")
      expect(records[1]["before"]).to eq(1500)
    end
  end

  # Одобренный план заменяет собой историю исследования — как резюме
  # при сворачивании, только написанное моделью и утверждённое человеком.
  # Без отметки лог выглядел бы так, будто модель посреди работы забыла
  # всё, что успела изучить.
  describe "одобрение плана" do
    it "отмечает сброс контекста вместе с путём к файлу" do
      log = described_class.new(path)
      log.message({ role: "user", content: "как добавить X?" })
      log.plan(before: 12, path: "/tmp/plans/план.md")
      log.close

      expect(records.map { |r| r["type"] }).to eq(%w[message plan])
      expect(records.last).to include("before" => 12, "path" => "/tmp/plans/план.md")
    end

    # Файл мог не записаться: права на каталог, полный диск. Работа при этом
    # продолжается, и отметка о сбросе нужна ровно так же.
    it "обходится без пути, когда файл не записался" do
      log = described_class.new(path)
      log.plan(before: 12)
      log.close

      expect(records.first["path"]).to be_nil
    end
  end

  # Размышления в историю не попадают вовсе, и журнал — единственное место,
  # где их видно. Нужны они ровно в том случае, ради которого лог и заводят:
  # при обрыве ответа иначе известно только, что текста нет, а не на чём
  # модель его потратила.
  describe "размышления модели" do
    it "пишет их отдельной записью, а не полем сообщения" do
      log = described_class.new(path)
      log.reasoning("надо посчитать 17*23")
      log.message({ role: "assistant", content: "391" })
      log.close

      expect(records.map { |r| r["type"] }).to eq(%w[reasoning message])
      expect(records.first["content"]).to eq("надо посчитать 17*23")
      expect(records.last).not_to have_key("reasoning")
    end

    # Модель без размышлений — обычное дело, и пустая запись на каждый ход
    # только мешала бы читать лог.
    it "молчит, когда размышлений не было" do
      log = described_class.new(path)
      log.reasoning("")
      log.reasoning(nil)
      log.close

      expect(records).to be_empty
    end
  end
end
