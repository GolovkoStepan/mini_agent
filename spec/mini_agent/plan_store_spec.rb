# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::PlanStore do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  # Часы фиксируются: имя файла содержит время, и без этого проверять
  # пришлось бы регулярным выражением, то есть почти не проверять.
  let(:clock) { double(now: Time.at(1_760_000_000).utc) }
  let(:dir) { File.join(@dir, "plans") }

  subject(:store) { described_class.new(dir: dir, clock: clock) }

  describe "запись" do
    it "кладёт план в файл и возвращает путь" do
      path = store.save("1. Прочитать.\n2. Написать.", task: "добавить кэш")

      expect(File.read(path)).to include("1. Прочитать.", "2. Написать.")
      expect(path).to start_with(dir)
    end

    # Дата в имени — чтобы планы сортировались по времени; задача — чтобы
    # через неделю понять, к чему относится этот файл.
    it "называет файл датой и задачей" do
      path = store.save("план", task: "добавить кэш")

      expect(File.basename(path)).to eq("2025-10-09-0853-добавить-кэш.md")
    end

    # Шапка: задача и время — чтобы понять, к чему это; модель и каталог —
    # по той же причине, что и в заголовке сессии журнала: план, составленный
    # другой моделью в другом проекте, выглядит точно так же.
    it "пишет шапку с задачей, моделью и каталогом" do
      config = MiniAgent::Config.new({ model: "qwen-test", cwd: @dir }, env: {})

      text = File.read(store.save("план", task: "добавить кэш", config: config))

      expect(text).to include("# добавить кэш", "qwen-test", @dir, "2025-10-09")
    end

    it "обходится без настроек" do
      expect(File.read(store.save("план", task: "задача"))).to include("план")
    end
  end

  describe "имя файла" do
    def name(task)
      File.basename(store.save("план", task: task))
    end

    # Транслитерации нет намеренно: задачи здесь пишут по-русски, и
    # pochini-testy читается хуже исходного.
    it "сохраняет кириллицу как есть" do
      expect(name("почини тесты")).to include("почини-тесты")
    end

    # [[:alnum:]], а не \w: тот в Ruby ограничен ASCII, и русская задача
    # схлопнулась бы в пустое имя целиком (те же грабли, что
    # у SlashCommands::PATTERN).
    it "выбрасывает всё, что не буква и не цифра" do
      expect(name("удали ../../etc/passwd; rm -rf /")).to eq("2025-10-09-0853-удали-etc-passwd-rm-rf.md")
    end

    it "обрезает длинную задачу" do
      slug = name("слово " * 40).sub("2025-10-09-0853-", "").sub(".md", "")

      expect(slug.length).to be <= described_class::SLUG_LIMIT
      expect(slug).not_to end_with("-")
    end

    # Из одних недопустимых знаков остаётся пустая строка, и файл получил бы
    # имя из одной даты — отличать такие планы друг от друга было бы нечем.
    it "не остаётся без имени вовсе" do
      expect(name("???")).to eq("2025-10-09-0853-plan.md")
    end
  end

  # Два плана по одной задаче в одну минуту — это обычная итерация «уточнить
  # и переспросить», и второй затирал бы первый ровно тогда, когда их и хотели
  # сравнить.
  describe "коллизии" do
    it "не перезаписывает существующий план" do
      first = store.save("первый", task: "задача")
      second = store.save("второй", task: "задача")

      expect(second).not_to eq(first)
      expect(File.read(first)).to include("первый")
      expect(File.read(second)).to include("второй")
    end

    it "нумерует со второго" do
      store.save("первый", task: "задача")
      store.save("второй", task: "задача")
      third = store.save("третий", task: "задача")

      expect(File.basename(third)).to eq("2025-10-09-0853-задача-3.md")
    end
  end

  describe "права" do
    # План пересказывает содержимое рабочего проекта, а тот бывает закрытым.
    it "закрывает каталог и файл от посторонних" do
      path = store.save("план", task: "задача")

      expect(format("%o", File.stat(dir).mode & 0o777)).to eq("700")
      expect(format("%o", File.stat(path).mode & 0o777)).to eq("600")
    end
  end

  # Незаписанный файл сессию не рушит: тот же выбор, что у Transcript,
  # и по той же причине — план нужен человеку, а потеря файла не отменяет
  # уже проделанной работы.
  describe "сбой записи" do
    it "возвращает nil и оставляет причину" do
      FileUtils.mkdir_p(dir)
      File.chmod(0o500, dir)

      expect(store.save("план", task: "задача")).to be_nil
      expect(store.error).not_to be_empty
    ensure
      File.chmod(0o700, dir)
    end

    # Иначе прошлая неудача осталась бы висеть на удачной записи, и разобрать,
    # к чему относится причина, было бы нельзя.
    it "забывает прошлую причину при удачной записи" do
      FileUtils.mkdir_p(dir)
      File.chmod(0o500, dir)
      store.save("план", task: "задача")
      File.chmod(0o700, dir)

      store.save("план", task: "задача")

      expect(store.error).to be_nil
    end
  end
  # Обратная сторона записи: файл, поправленный в редакторе, читается тем же
  # классом, что его писал. Шапка и её разбор — пара «формат и его разбор»,
  # и жить она обязана в одном месте.
  describe ".body" do
    it "отрезает шапку" do
      saved = store.save("1. Прочитать.", task: "как добавить X?")

      expect(described_class.body(saved)).to eq("1. Прочитать.")
    end

    it "возвращает правки целиком" do
      saved = store.save("1. Прочитать.", task: "как добавить X?")
      File.write(saved, File.read(saved).sub("1. Прочитать.", "1. Прочитать.
2. Написать."))

      expect(described_class.body(saved)).to eq("1. Прочитать.
2. Написать.")
    end

    # Заголовки внутри плана начинаются с ## или идут после пустой строки —
    # под образец шапки они не подходят, и терять их нельзя.
    it "не принимает заголовки плана за шапку" do
      saved = store.save("## Шаги

1. Прочитать.", task: "как добавить X?")

      expect(described_class.body(saved)).to eq("## Шаги

1. Прочитать.")
    end

    it "отдаёт пустую строку у опустевшего файла" do
      saved = store.save("план", task: "задача")
      File.write(saved, "")

      expect(described_class.body(saved)).to eq("")
    end
  end
end
