# frozen_string_literal: true

RSpec.describe MiniAgent::Plural do
  def knak(count) = described_class.with(count, "знак", "знака", "знаков")

  it "согласует единственное число" do
    expect(knak(1)).to eq("1 знак")
    expect(knak(21)).to eq("21 знак")
    expect(knak(101)).to eq("101 знак")
  end

  it "согласует форму для двух-четырёх" do
    expect(knak(2)).to eq("2 знака")
    expect(knak(34)).to eq("34 знака")
    expect(knak(123)).to eq("123 знака")
  end

  it "согласует множественное число" do
    expect(knak(5)).to eq("5 знаков")
    expect(knak(100)).to eq("100 знаков")
    expect(knak(791)).to eq("791 знак")
  end

  # Ровно тот случай, ради которого правило считается по двум последним
  # цифрам, а не по одной: 11 кончается на 1, но ведёт себя как 5.
  it "не путает 11-14 с 1-4" do
    expect(knak(11)).to eq("11 знаков")
    expect(knak(12)).to eq("12 знаков")
    expect(knak(14)).to eq("14 знаков")
    expect(knak(111)).to eq("111 знаков")
  end

  it "считает ноль множественным" do
    expect(knak(0)).to eq("0 знаков")
  end
end
