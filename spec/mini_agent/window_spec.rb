# frozen_string_literal: true

RSpec.describe MiniAgent::Window do
  def window(size:, prompt: nil, max_tokens: 0)
    described_class.new(size: size, prompt_tokens: prompt, max_tokens: max_tokens)
  end

  describe "незнание" do
    it "не знает размера без него" do
      expect(window(size: nil, prompt: 500)).not_to be_known
    end

    # Ноль пришёл бы от --context-window 0 или от сервера с испорченным
    # ответом. Считать его размером окна значило бы делить на ноль.
    it "не считает ноль размером окна" do
      expect(window(size: 0, prompt: 500)).not_to be_known
    end

    # Размер известен, но сервер не прислал usage: считать долю не от чего.
    it "не меряет без данных о промпте" do
      expect(window(size: 8192)).not_to be_measurable
      expect(window(size: 8192, prompt: 0)).not_to be_measurable
    end

    it "молчит обо всём остальном, пока мерить нечем" do
      unknown = window(size: nil, prompt: 500, max_tokens: 100)

      expect(unknown.percent).to eq(0)
      expect(unknown.occupied).to eq(0)
      expect(unknown.free).to be_nil
      expect(unknown).not_to be_tight
      expect(unknown).not_to be_starved
    end
  end

  describe "заполнение" do
    # Резерв под ответ входит в занятое: обе части претендуют на одно окно.
    it "считает занятым промпт вместе с резервом под ответ" do
      expect(window(size: 8192, prompt: 2000, max_tokens: 1000).occupied).to eq(3000)
    end

    it "считает долю от размера окна" do
      expect(window(size: 8192, prompt: 2000, max_tokens: 1000).percent).to eq(37)
    end

    it "оставляет на генерацию остаток окна после истории" do
      expect(window(size: 8192, prompt: 2000, max_tokens: 1000).free).to eq(6192)
    end

    # Округлять вниз до 100% значило бы спрятать ровно тот случай,
    # ради которого отчёт и заводится.
    it "показывает больше ста процентов, когда max_tokens не влезает" do
      expect(window(size: 8192, prompt: 7000, max_tokens: 4096).percent).to eq(135)
    end

    # Слагаемые для отчёта: окно показывается разложенным, а не одной
    # суммой — «5058 из 8192» не отвечало, занято это или свободно.
    it "отдаёт промпт слагаемым" do
      expect(window(size: 8192, prompt: 2000, max_tokens: 1000).prompt_tokens).to eq(2000)
      expect(window(size: 8192, max_tokens: 1000).prompt_tokens).to eq(0)
    end

    # Отдельно от free: тот про «сколько дадут сгенерировать», этот про
    # «сходится ли бюджет вообще».
    it "считает остаток после истории и резерва" do
      expect(window(size: 8192, prompt: 2000, max_tokens: 1000).remaining).to eq(5192)
    end

    it "уходит в минус, когда резерв в окно не помещается" do
      expect(window(size: 8192, prompt: 5000, max_tokens: 8000).remaining).to eq(-4808)
    end

    it "молчит об остатке, пока мерить нечем" do
      expect(window(size: nil, prompt: 500, max_tokens: 100).remaining).to eq(0)
    end
  end

  describe "предупреждения" do
    it "молчит на просторном окне" do
      roomy = window(size: 8192, prompt: 1000, max_tokens: 1000)

      expect(roomy).not_to be_tight
      expect(roomy).not_to be_starved
    end

    it "сообщает о тесноте с трёх четвертей" do
      expect(window(size: 8192, prompt: 5144, max_tokens: 1000)).to be_tight
    end

    # Ровно на пороге — уже тесно: WARN_AT это «с», а не «после».
    it "срабатывает ровно на пороге" do
      expect(window(size: 1000, prompt: 750, max_tokens: 0).percent).to eq(75)
      expect(window(size: 1000, prompt: 750, max_tokens: 0)).to be_tight
    end

    # Тот самый случай из живой работы: max_tokens 4096 при окне 8192.
    # Лечится не сворачиванием, а уменьшением лимита, — потому признак
    # и держится отдельно от tight?.
    it "отдельно сообщает, что на ответ места не осталось" do
      starved = window(size: 8192, prompt: 5000, max_tokens: 4096)

      expect(starved).to be_starved
      expect(starved.free).to eq(3192)
    end

    it "не путает тесноту с нехваткой места на ответ" do
      # Тесно, но ответ ещё помещается: 6500 + 200 из 8192, свободно 1692.
      tight = window(size: 8192, prompt: 6500, max_tokens: 200)

      expect(tight).to be_tight
      expect(tight).not_to be_starved
    end
  end
end
