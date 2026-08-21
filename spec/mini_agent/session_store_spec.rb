# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::SessionStore do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  # Время в имени файла: без подмены часов проверять пришлось бы регулярным
  # выражением, то есть не проверять вовсе (тот же приём, что у PlanStore).
  let(:clock) { class_double(Time, now: Time.new(2026, 8, 21, 10, 29, 30)) }

  def store(dir = @dir) = described_class.new(dir: dir, clock: clock)

  # Заголовок пишет Transcript, и второго писателя у сессий нет: файл здесь
  # заводится тем же способом, каким его заведёт агент.
  def session(cwd, dir = @dir)
    path = described_class.new(dir: dir, clock: clock).path(cwd)
    File.write(path, "#{JSON.generate(type: "session", cwd: cwd)}\n")
    path
  end

  describe "новый файл" do
    it "кладёт сессию в свой каталог с датой и именем проекта" do
      expect(File.basename(store.path("/home/user/mini_agent"))).to eq("2026-08-21-102930-mini-agent.jsonl")
    end

    it "создаёт каталог, если его не было" do
      path = store(File.join(@dir, "нет", "ещё")).path("/tmp/x")

      expect(Dir.exist?(File.dirname(path))).to be(true)
    end

    # Оценочные задачи запускают агента подряд, и две сессии в одну секунду —
    # обычное дело. Затирание отняло бы ровно ту сессию, которую продолжают.
    it "не занимает уже существующее имя" do
      first = store.path("/tmp/проект")
      File.write(first, "")

      expect(store.path("/tmp/проект")).not_to eq(first)
    end

    it "не роняет запуск, когда каталог не создаётся" do
      blocked = File.join(@dir, "файл")
      File.write(blocked, "")
      broken = store(File.join(blocked, "сессии"))

      expect(broken.path("/tmp/x")).to be_nil
      expect(broken.error).not_to be_empty
    end

    # Каталог без букв и цифр («/», «~/...») дал бы имя из одной даты.
    it "подставляет запасное имя, когда слаг пустой" do
      expect(store.path("/")).to end_with("-session.jsonl")
    end
  end

  describe "последняя сессия" do
    it "находит сессию этого каталога" do
      path = session("/tmp/проект")

      expect(store.latest("/tmp/проект")).to eq(path)
    end

    # Слаг обрезан и берётся от последнего сегмента: у ~/work/agent и
    # ~/tmp/agent имена файлов совпадут. Продолжить чужую сессию молча
    # хуже, чем не найти ни одной, — история уедет модели целиком.
    it "не отдаёт сессию другого каталога" do
      session("/tmp/другой")

      expect(store.latest("/tmp/проект")).to be_nil
    end

    # По времени изменения, а не по имени: продолжают ту сессию, в которой
    # работали последней, а не ту, которую позже завели.
    it "берёт ту, в которой работали последней" do
      older = session("/tmp/проект")
      newer = session("/tmp/проект")
      File.utime(Time.now + 60, Time.now + 60, older)

      expect(store.latest("/tmp/проект")).to eq(older)
      expect(newer).not_to eq(older)
    end

    it "молчит, когда сессий нет вовсе" do
      expect(store(File.join(@dir, "пусто")).latest("/tmp/проект")).to be_nil
    end

    # Файл убитого процесса мог оборваться на первой же строке. Выбор сессии
    # из-за этого падать не должен — тем более что рядом лежат целые.
    it "пропускает файл с битым заголовком" do
      File.write(File.join(@dir, "битая.jsonl"), "{не json\n")
      path = session("/tmp/проект")
      File.utime(Time.now - 60, Time.now - 60, path)

      expect(store.latest("/tmp/проект")).to eq(path)
    end
  end
end
