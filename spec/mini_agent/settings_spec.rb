# frozen_string_literal: true

require "tmpdir"

RSpec.describe MiniAgent::Settings do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  # Настоящий ~/.mini_agent/settings.json тесты не трогают ни на чтение,
  # ни на запись: путь всегда задаётся явно. Тот же приём, что в plan_store_spec,
  # и та же причина — домашний каталог принадлежит человеку, а не тестам.
  let(:path) { File.join(@dir, "settings.json") }

  def write(text)
    File.write(path, text)
    path
  end

  describe "чтение" do
    it "отдаёт значения файла и его путь" do
      settings = described_class.load(write('{"model": "из-файла", "temperature": 0.3}'))

      expect(settings.values).to eq(model: "из-файла", temperature: 0.3)
      expect(settings.path).to eq(path)
    end

    # Ключи сэмплинга и есть повод заводить файл: умолчаний у них нет,
    # а восемь флагов при каждом запуске набирать некому.
    it "принимает ключи сэмплинга, у которых нет умолчаний" do
      settings = described_class.load(write('{"top_k": 40, "repeat_penalty": 1.05, "seed": 7}'))

      expect(settings.values).to eq(top_k: 40, repeat_penalty: 1.05, seed: 7)
    end

    # JSON приносит настоящие типы, и приводить их не нужно: false остаётся
    # false, а не строкой «false», которую пришлось бы разбирать заново.
    it "сохраняет типы значений" do
      settings = described_class.load(write('{"stream": false, "max_tokens": 4096}'))

      expect(settings.values).to eq(stream: false, max_tokens: 4096)
    end

    it "не читает файл при enabled: false" do
      settings = described_class.load(write('{"model": "из-файла"}'), enabled: false)

      expect(settings.values).to be_empty
      expect(settings.path).to be_nil
    end
  end

  describe "отсутствие файла" do
    # Умолчательного файла у большинства нет вовсе, и это не повод для ошибки.
    # Путь подменяется, а не берётся настоящий: у разработчика файл может
    # и лежать, и тогда тест проверял бы содержимое чужого домашнего каталога.
    it "молчит, когда файла по умолчанию нет" do
      stub_const("#{described_class}::PATH", File.join(@dir, "нет.json"))

      expect(described_class.load.path).to be_nil
    end

    # А вот названный и отсутствующий означает работу с чужими настройками
    # при полной уверенности в своих: опечатка в пути молча не прощается.
    it "отказывается работать, когда названный файл не найден" do
      expect { described_class.load(path) }
        .to raise_error(MiniAgent::ConfigError, /не найден.*settings\.json/m)
    end
  end

  describe "испорченный файл" do
    it "называет путь и причину при битом JSON" do
      expect { described_class.load(write("{модель}")) }
        .to raise_error(MiniAgent::ConfigError, /испорчен.*settings\.json/m)
    end

    # Отдельно от битого JSON: файл есть, но прочитать его не выходит —
    # чаще всего из-за прав, выставленных ради лежащего в нём api_key.
    # Молчаливый откат к умолчаниям выглядел бы так же, как удачное чтение.
    it "называет путь и причину, когда файл не читается" do
      write('{"model": "из-файла"}')
      File.chmod(0o000, path)
      skip "запущено от root: права не мешают чтению" if File.readable?(path)

      expect { described_class.load(path) }
        .to raise_error(MiniAgent::ConfigError, /Не удалось прочитать.*settings\.json/m)
    end

    # Массив на верхнем уровне разбирается успешно, но настройками не является:
    # молчаливый откат к умолчаниям неотличим от «файл прочитан».
    it "требует объект на верхнем уровне" do
      expect { described_class.load(write('["model"]')) }
        .to raise_error(MiniAgent::ConfigError, /объект JSON/)
    end
  end

  describe "неизвестный ключ" do
    # Файл пишут один раз и потом не перечитывают, а «max_token» без s
    # выглядит рабочим ровно до того дня, когда понадобится.
    it "отказывается работать и подсказывает ближайший" do
      expect { described_class.load(write('{"max_token": 4096}')) }
        .to raise_error(MiniAgent::ConfigError, /«max_token».*max_tokens/m)
    end

    # Действия CLI настройками не являются: их не «задают на будущее»,
    # ими запускают то, ради чего агента позвали в этот раз.
    it "не принимает действия командной строки" do
      expect { described_class.load(write('{"interactive": true}')) }
        .to raise_error(MiniAgent::ConfigError, /«interactive»/)
    end
  end

  describe ".from_options" do
    it "читает названный файл" do
      expect(described_class.from_options(settings: write('{"model": "из-файла"}')).values)
        .to eq(model: "из-файла")
    end

    # OptionParser считает «--no-» отрицанием и кладёт в options ложь:
    # признаком набранного флага является наличие ключа, а не его значение.
    # Проверка на истинность пропускала бы --no-settings всегда.
    it "видит --no-settings по наличию ключа, а не по значению" do
      expect(described_class.from_options({ no_settings: false }).path).to be_nil
    end

    it "отказывается выбирать между --settings и --no-settings" do
      expect { described_class.from_options(settings: path, no_settings: false) }
        .to raise_error(MiniAgent::ConfigError, /--settings.*--no-settings/)
    end
  end
end
