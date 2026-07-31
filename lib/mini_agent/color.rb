# frozen_string_literal: true

module MiniAgent
  # Раскраска вывода ANSI-последовательностями.
  #
  # В исходном скрипте это был refinement для String. Refinement действует
  # лексически — только в том файле, где написан `using`, — поэтому при
  # разбиении на несколько файлов он неудобен. Здесь обычный модуль с
  # функциями: цвет применяется явно, глобальное состояние не трогается.
  module Color
    CODES = {
      red: "\e[31m",
      green: "\e[32m",
      yellow: "\e[33m",
      blue: "\e[34m",
      cyan: "\e[36m",
      # Серый берётся из 256-цветного куба, а не из базовой палитры.
      # \e[37m (обычный белый) сливается с текстом на светлой теме,
      # а \e[90m (bright black) в тёмных темах уходит почти в чёрный —
      # вывод инструментов становится нечитаемым. 245 — середина серой
      # шкалы: заметно приглушён относительно основного текста, но
      # контрастен и на тёмном, и на светлом фоне.
      gray: "\e[38;5;245m",
      dim: "\e[2m",
      bold: "\e[1m"
    }.freeze

    RESET = "\e[0m"

    module_function

    # enabled: false отдаёт текст без ANSI-кодов — так тесты сравнивают
    # чистые строки, а перенаправление вывода в файл не засоряется escape-кодами.
    def paint(text, *styles, enabled: true)
      return text.to_s unless enabled

      prefix = styles.filter_map { |s| CODES[s] }.join
      return text.to_s if prefix.empty?

      "#{prefix}#{text}#{RESET}"
    end

    # Короткие обёртки вида Color.red("текст") для каждого стиля.
    CODES.each_key do |style|
      define_method(style) { |text, enabled: true| paint(text, style, enabled: enabled) }
    end

    module_function(*CODES.keys)
  end
end
