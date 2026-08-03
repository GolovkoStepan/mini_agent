# frozen_string_literal: true

module MiniAgent
  # Согласование существительного с числом по-русски.
  #
  # Нужен потому, что в интерфейсе, целиком написанном по-русски, «34 знаков»
  # и «791 токенов» читаются как недоделка — ровно там, где всё остальное
  # выверено. Найдено живой проверкой /context.
  #
  # Форм три: 1 знак, 2 знака, 5 знаков. Правило считается по последним двум
  # цифрам, потому что 11–14 ведут себя не как 1–4: «21 знак», но «11 знаков».
  module Plural
    def self.form(count, one, few, many)
      count = count.abs
      return many if (11..14).cover?(count % 100)

      case count % 10
      when 1 then one
      when 2, 3, 4 then few
      else many
      end
    end

    # Число вместе с согласованным словом: «1 знак», «34 знака».
    def self.with(count, one, few, many)
      "#{count} #{form(count, one, few, many)}"
    end
  end
end
