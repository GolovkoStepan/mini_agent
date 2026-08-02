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

        expect(loaded.bytesize).to be <= described_class::MAX_SIZE + 100
        expect(loaded).to include("обрезано")
      end

      it "не трогает файл в пределах потолка" do
        write("AGENTS.md", "коротко")

        expect(context.load).to eq("коротко")
      end

      # byteslice режет по байтам и может разрубить многобайтовый символ.
      it "не оставляет битых символов при обрезке" do
        write("AGENTS.md", "яяя\n" * 20_000)

        expect(context.load).to be_valid_encoding
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
