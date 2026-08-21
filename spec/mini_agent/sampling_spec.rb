# frozen_string_literal: true

RSpec.describe MiniAgent::Sampling do
  def sampling(options = {}, env = {})
    MiniAgent::Config.new(options, env: env).sampling
  end

  describe "молчание по умолчанию" do
    # Главное свойство класса: чего не задали, того в теле запроса нет.
    # Пустой хеш здесь означает «всё решает пресет сервера».
    it "не задаёт ни одного параметра, когда о них не просили" do
      expect(sampling).to eq({})
    end

    it "не подставляет температуру взамен убранной константы" do
      expect(sampling).not_to have_key(:temperature)
    end
  end

  describe "источники значений" do
    it "берёт параметр из опции" do
      expect(sampling({ temperature: 0.3 })).to eq({ temperature: 0.3 })
    end

    it "берёт параметр из переменной окружения" do
      expect(sampling({}, { "LLM_TEMPERATURE" => "0.3" })).to eq({ temperature: 0.3 })
    end

    it "предпочитает опцию переменной окружения" do
      result = sampling({ temperature: 0.7 }, { "LLM_TEMPERATURE" => "0.1" })

      expect(result).to eq({ temperature: 0.7 })
    end

    it "собирает вместе всё заданное" do
      result = sampling({ temperature: 0.3, top_k: 50, repeat_penalty: 1.12 })

      expect(result).to eq({ temperature: 0.3, top_k: 50, repeat_penalty: 1.12 })
    end

    it "знает все восемь параметров протокола" do
      env = {
        "LLM_TEMPERATURE" => "0.3", "LLM_TOP_P" => "0.9", "LLM_TOP_K" => "50",
        "LLM_MIN_P" => "0.05", "LLM_REPEAT_PENALTY" => "1.12",
        "LLM_PRESENCE_PENALTY" => "0.05", "LLM_FREQUENCY_PENALTY" => "0.1",
        "LLM_SEED" => "42"
      }

      expect(sampling({}, env).keys).to match_array(described_class::KEYS.keys)
    end
  end

  describe "разбор чисел" do
    it "читает целое там, где протокол ждёт целое" do
      expect(sampling({}, { "LLM_TOP_K" => "50" })).to eq({ top_k: 50 })
    end

    it "читает дробное там, где протокол ждёт дробное" do
      expect(sampling({}, { "LLM_MIN_P" => "0.05" })).to eq({ min_p: 0.05 })
    end

    # to_f превратил бы мусор в правдоподобный 0.0, и агент работал бы
    # с чужим значением молча — худший из исходов для числа, которое
    # определяет поведение модели.
    it "роняет запуск на нечисловом значении, а не превращает его в ноль" do
      expect { sampling({}, { "LLM_TEMPERATURE" => "abc" }) }
        .to raise_error(MiniAgent::ConfigError, /LLM_TEMPERATURE|temperature/)
    end

    it "роняет запуск на дробном там, где ждут целое" do
      expect { sampling({}, { "LLM_TOP_K" => "0.5" }) }.to raise_error(MiniAgent::ConfigError)
    end

    # Границы у каждого сервера свои; неприемлемое значение отвергнет он сам.
    it "не проверяет диапазонов" do
      expect(sampling({ temperature: 99.0, top_k: -1 })).to eq({ temperature: 99.0, top_k: -1 })
    end
  end

  describe "разные штрафы за повтор" do
    # repeat_penalty делит логиты (нейтраль 1.0), frequency_penalty вычитает
    # (нейтраль 0). Подмена одного другим означала бы почти максимальный
    # штраф там, где просили слабый, — поэтому ручки независимы.
    it "не путает repeat_penalty с frequency_penalty" do
      result = sampling({ repeat_penalty: 1.12, frequency_penalty: 0.1 })

      expect(result).to eq({ repeat_penalty: 1.12, frequency_penalty: 0.1 })
    end

    it "шлёт repeat_penalty под его собственным именем" do
      expect(sampling({ repeat_penalty: 1.12 })).to eq({ repeat_penalty: 1.12 })
    end
  end

  describe "общая форма --sampling" do
    it "раскладывает пару по отдельному ключу" do
      expect(sampling({ sampling: ["temperature=0.3"] })).to eq({ temperature: 0.3 })
    end

    it "принимает несколько пар в одном флаге через запятую" do
      expect(sampling({ sampling: ["temperature=0.3,top_k=50"] })).to eq({ temperature: 0.3, top_k: 50 })
    end

    it "принимает несколько пар через пробел" do
      expect(sampling({ sampling: ["min_p=0.05 seed=42"] })).to eq({ min_p: 0.05, seed: 42 })
    end

    # Затирание было бы молчаливым: два указания, действует одно.
    it "копит пары из повторённого флага" do
      result = sampling({ sampling: ["top_k=50", "temperature=0.3"] })

      expect(result).to eq({ top_k: 50, temperature: 0.3 })
    end

    it "разбирает значение так же, как именованный флаг" do
      expect(sampling({ sampling: ["top_k=50"] })).to eq(sampling({ top_k: 50 }))
    end

    # Ради этой проверки общая форма и заводится: пересланная как есть
    # опечатка молча игнорируется сервером, и флаг выглядит рабочим.
    it "роняет запуск на неизвестном ключе, а не шлёт его серверу" do
      expect { sampling({ sampling: ["temperatur=0.3"] }) }
        .to raise_error(MiniAgent::ConfigError, /temperatur/)
    end

    it "подсказывает ближайший известный ключ" do
      expect { sampling({ sampling: ["temperatur=0.3"] }) }
        .to raise_error(MiniAgent::ConfigError, /имелось в виду «temperature»/)
    end

    # Запятая-разделитель разрежет «0,3» пополам, и обломок «3» упрётся сюда.
    it "требует вид ключ=значение" do
      expect { sampling({ sampling: ["temperature=0,3"] }) }
        .to raise_error(MiniAgent::ConfigError, /дробная часть — точкой/)
    end

    # Тот же выбор, что у --settings вместе с --no-settings: указания
    # противоречат друг другу, и ни одно не точнее другого.
    it "не выбирает между отдельным флагом и общей формой" do
      expect { sampling({ temperature: 0.7, sampling: ["temperature=0.3"] }) }
        .to raise_error(MiniAgent::ConfigError, /и отдельным флагом, и в --sampling/)
    end

    it "не выбирает между двумя одинаковыми ключами в общей форме" do
      expect { sampling({ sampling: ["top_k=50", "top_k=20"] }) }
        .to raise_error(MiniAgent::ConfigError, /дважды/)
    end

    # Разложенная пара — обычная опция, а не свой источник значений:
    # иначе Lookup#given? видел бы одно число в двух местах.
    it "перебивает переменную окружения, как и именованный флаг" do
      result = sampling({ sampling: ["temperature=0.7"] }, { "LLM_TEMPERATURE" => "0.1" })

      expect(result).to eq({ temperature: 0.7 })
    end

    it "не задаёт ничего, когда флаг не набран" do
      expect(sampling({ sampling: [] })).to eq({})
    end
  end

  # Значения не должны разъезжаться между вызовами, а ConfigError обязан
  # прилетать на старте, а не на десятом ходу.
  it "разбирает параметры один раз" do
    config = MiniAgent::Config.new({ temperature: 0.3 }, env: {})

    expect(config.sampling).to equal(config.sampling)
  end
end
