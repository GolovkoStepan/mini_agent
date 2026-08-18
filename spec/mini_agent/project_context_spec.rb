# frozen_string_literal: true

RSpec.describe MiniAgent::ProjectContext do
  around do |example|
    Dir.mktmpdir { |dir| example.run(@dir = dir) }
  end

  def write(name, content)
    File.write(File.join(@dir, name), content)
  end

  subject(:context) { described_class.new(@dir) }

  describe "#load" do
    it "возвращает nil, когда описания нет" do
      expect(context.load).to be_nil
    end

    it "читает AGENTS.md" do
      write("AGENTS.md", "Тесты запускаются через make spec")

      expect(context.load).to eq("Тесты запускаются через make spec")
    end

    it "читает .mini_agent.md" do
      write(".mini_agent.md", "Своё описание")

      expect(context.load).to eq("Своё описание")
    end

    # Склейка двух файлов дала бы противоречивые указания без способа
    # их развести, поэтому побеждает первое найденное имя.
    it "предпочитает AGENTS.md, когда есть оба" do
      write("AGENTS.md", "общий")
      write(".mini_agent.md", "личный")

      expect(context.load).to eq("общий")
    end

    it "считает пустой файл отсутствующим" do
      write("AGENTS.md", "   \n\n  ")

      expect(context.load).to be_nil
    end

    # Агент прекрасно работает и без описания проекта: разбираться с правами
    # доступа посреди задачи незачем.
    it "не падает на нечитаемом файле" do
      path = File.join(@dir, "AGENTS.md")
      File.write(path, "содержимое")
      File.chmod(0o000, path)

      skip "тест бессмыслен под root: чтение разрешено вопреки правам" if File.readable?(path)

      expect(context.load).to be_nil
    end

    describe "ограничение размера" do
      # Файл больше потолка — это уже документация проекта, а не описание,
      # и она вытеснит из контекстного окна саму задачу.
      it "обрезает слишком большой файл" do
        write("AGENTS.md", "строка описания\n" * 5000)

        loaded = context.load

        expect(loaded.size).to be <= described_class::MAX_CHARS + 100
        expect(loaded).to include("обрезано")
      end

      it "не трогает файл в пределах потолка" do
        write("AGENTS.md", "коротко")

        expect(context.load).to eq("коротко")
      end

      # Файл может прийти с негодными байтами, и всплывает это далеко от
      # места — JSON::GeneratorError при сборке тела запроса.
      it "не оставляет битых символов" do
        write("AGENTS.md", "яяя\n" * 20_000)

        expect(context.load).to be_valid_encoding
      end
    end

    # Потолок в знаках сам по себе не спасает: 20 000 знаков — это около
    # 6000 токенов, то есть больше окна в 8192 вместе с резервом под ответ.
    # Найдено живой проверкой 2026-08-02: каждый запрос падал с HTTP 400,
    # и /clear не помогал, потому что описание попадает и в новую историю.
    describe "ограничение по контекстному окну" do
      it "режет описание по доле окна, когда его размер известен" do
        write("AGENTS.md", "строка описания\n" * 5000)

        loaded = described_class.new(@dir, window: 8192).load

        expect(loaded.size).to be <= (8192 * described_class::SHARE * described_class::CHARS_PER_TOKEN) + 100
        expect(loaded).to include("обрезано")
      end

      # Большое окно не делает документацию описанием: потолок остаётся
      # потолком, как и у max_tokens.
      it "не поднимает потолок на большом окне" do
        write("AGENTS.md", "строка описания\n" * 5000)

        loaded = described_class.new(@dir, window: 262_144).load

        expect(loaded.size).to be <= described_class::MAX_CHARS + 100
      end

      it "оставляет короткое описание целиком и при маленьком окне" do
        write("AGENTS.md", "коротко")

        expect(described_class.new(@dir, window: 8192).load).to eq("коротко")
      end
    end

    # Числа нужны AgentBuilder: урезанное описание — молчаливая потеря знаний
    # о проекте, и сказать об этом можно только цифрами.
    describe "#truncated?" do
      it "сообщает, что описание урезано, и на сколько" do
        write("AGENTS.md", "строка описания\n" * 5000)
        context.load

        expect(context).to be_truncated
        expect(context.total).to eq(80_000)
        expect(context.kept).to be < context.total
      end

      it "молчит, когда описание влезло целиком" do
        write("AGENTS.md", "коротко")
        context.load

        expect(context).not_to be_truncated
        expect(context.kept).to eq(context.total)
      end
    end

    # Причин обрезки две, и лечения у них разные: окно раздвигается загрузкой
    # модели с бо́льшим ctx, потолок — только правкой файла. Найдено живой
    # проверкой: при окне 60416 резал потолок, а сообщение винило окно.
    describe "#limited_by" do
      it "называет окно, когда доля окна меньше потолка" do
        expect(described_class.new(@dir, window: 8192).limited_by).to eq(:window)
      end

      it "называет потолок, когда окно просторное" do
        expect(described_class.new(@dir, window: 262_144).limited_by).to eq(:ceiling)
      end

      it "называет потолок, когда размер окна неизвестен" do
        expect(described_class.new(@dir).limited_by).to eq(:ceiling)
      end
    end
  end

  describe "#filename" do
    it "возвращает имя найденного файла" do
      write(".mini_agent.md", "текст")

      expect(context.filename).to eq(".mini_agent.md")
    end

    it "возвращает nil, когда файла нет" do
      expect(context.filename).to be_nil
    end
  end

  describe ".load" do
    it "читает из указанного каталога" do
      write("AGENTS.md", "из каталога")

      expect(described_class.load(@dir)).to eq("из каталога")
    end
  end
end
