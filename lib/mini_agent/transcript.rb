# frozen_string_literal: true

require "json"
require "time"

module MiniAgent
  # Запись диалога в файл: по одному объекту JSON на строку (JSONL).
  #
  # Пишется каждое сообщение по мере появления, а не история целиком в конце.
  # Разбираться в логе приходится как раз тогда, когда конца не случилось:
  # процесс упал, завис или его убили. Дамп на выходе в этих случаях
  # не сохранился бы ни разу.
  #
  # По той же причине поток несинхронизированный не годится: буфер уходит
  # вместе с процессом. sync = true платит системным вызовом на сообщение —
  # на фоне запроса к модели это ничто.
  class Transcript
    def initialize(path, ui: nil, clock: Time)
      @path = path
      @ui = ui
      @clock = clock
      @io = File.open(path, "a")
      @io.sync = true
    rescue SystemCallError => e
      raise ConfigError, format(Messages::LOG_OPEN_FAILED, path: path, message: e.message)
    end

    attr_reader :path

    # Заголовок сессии: в файл пишутся подряд несколько запусков, и без него
    # непонятно, где кончился прошлый и какой моделью сделан этот.
    #
    # api_key сюда не попадает намеренно. Лог заводят, чтобы показать его
    # кому-то ещё или приложить к отчёту, а ключ в нём — утечка, которую
    # никто не заметит.
    def session(config)
      write(
        type: "session",
        model: config.model,
        base_url: config.base_url,
        cwd: config.cwd || Dir.pwd
      )
    end

    def message(message)
      write({ type: "message" }.merge(message))
    end

    # Ход не удался, и его сообщения сняты с истории. Записываем это отдельной
    # строкой, а не вычёркиваем их из файла: журнал протоколирует то, что
    # действительно уходило модели. Молчаливое удаление развело бы лог
    # с историей, и понять по нему, почему запрос упал, стало бы нельзя.
    def rollback(count)
      write(type: "rollback", removed: count)
    end

    # Диалог свёрнут в резюме. Как и при откате, прежние сообщения из файла
    # не вычёркиваются: они действительно уходили модели, и журнал об этом
    # свидетельствует. Без отметки лог выглядел бы так, будто модель ни
    # с того ни с сего получила пересказ собственного разговора.
    #
    # Размер только «до»: запись делается перед сборкой новой истории (иначе
    # оказалась бы внутри неё), и размера «после» в этот момент ещё нет.
    # Что получилось, видно по сообщениям, идущим следом.
    def compact(before:)
      write(type: "compact", before: before)
    end

    def close
      @io&.close
      @io = nil
    end

    private

    # Сбой записи не должен ронять агента: лог — диагностика, а не работа,
    # ради которой его запустили. Сообщаем один раз и замолкаем, иначе
    # предупреждение повторялось бы на каждом сообщении.
    def write(record)
      return unless @io

      @io.puts(JSON.generate(record.merge(time: @clock.now.iso8601)))
    rescue StandardError => e
      @ui&.warn(format(Messages::LOG_WRITE_FAILED, message: e.message))
      close
    end
  end
end
