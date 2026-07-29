# frozen_string_literal: true

RSpec.describe MiniAgent::Prompt do
  def prompt_with(answer)
    described_class.new(input: StringIO.new(answer), output: StringIO.new)
  end

  it "принимает ответ y" do
    expect(prompt_with("y\n").confirm?("Продолжить? ")).to be(true)
  end

  it "принимает ответ в верхнем регистре" do
    expect(prompt_with("Y\n").confirm?("Продолжить? ")).to be(true)
  end

  it "отклоняет ответ n" do
    expect(prompt_with("n\n").confirm?("Продолжить? ")).to be(false)
  end

  it "отклоняет пустой ответ" do
    expect(prompt_with("\n").confirm?("Продолжить? ")).to be(false)
  end

  it "отклоняет произвольный текст" do
    expect(prompt_with("да\n").confirm?("Продолжить? ")).to be(false)
  end

  # Ctrl+D закрывает поток: gets возвращает nil, и это не должно падать.
  it "отклоняет при обрыве ввода" do
    expect(prompt_with("").confirm?("Продолжить? ")).to be(false)
  end

  it "печатает вопрос" do
    output = StringIO.new
    described_class.new(input: StringIO.new("y\n"), output: output).confirm?("Продолжить? ")

    expect(output.string).to eq("Продолжить? ")
  end

  describe MiniAgent::Prompt::AutoApprove do
    it "всегда подтверждает" do
      expect(described_class.new.confirm?("что угодно")).to be(true)
    end
  end

  describe MiniAgent::Prompt::AutoDeny do
    it "всегда отказывает" do
      expect(described_class.new.confirm?("что угодно")).to be(false)
    end
  end
end
