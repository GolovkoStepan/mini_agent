# frozen_string_literal: true

RSpec.describe MiniAgent::Terminal do
  describe ".width" do
    # Вывод перенаправлен, ioctl не отвечает, окна нет вовсе — во всех трёх
    # случаях число всё равно нужно: по нему режется бегущая строка и
    # переносится разметка.
    it "берёт умолчание, когда терминала нет" do
      allow(IO).to receive(:console).and_return(nil)

      expect(described_class.width).to eq(described_class::DEFAULT_WIDTH)
    end

    it "спрашивает у терминала" do
      allow(IO).to receive(:console).and_return(double(winsize: [24, 132]))

      expect(described_class.width).to eq(132)
    end

    # Ноль — это не ширина, а «узнать не вышло»: делить по нему нельзя,
    # а перенос по нулю дал бы по слову на строку.
    it "не принимает ноль за ширину" do
      allow(IO).to receive(:console).and_return(double(winsize: [24, 0]))

      expect(described_class.width).to eq(described_class::DEFAULT_WIDTH)
    end

    # ioctl на закрытом или необычном устройстве бросает — падать из-за
    # оформления вывода агент не должен.
    it "переживает отказ ioctl" do
      allow(IO).to receive(:console).and_raise(Errno::ENOTTY)

      expect(described_class.width).to eq(described_class::DEFAULT_WIDTH)
    end
  end
end
