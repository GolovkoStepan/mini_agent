# frozen_string_literal: true

require "open3"

module MiniAgent
  # Запуск shell-команды с жёстким ограничением по времени.
  #
  # Namespace::Timeout.timeout здесь намеренно не используется: он бросает
  # исключение в поток, но не убивает порождённый процесс — тот остаётся
  # висеть в фоне. Вместо этого процесс убивается сигналом KILL явно.
  #
  # stdout и stderr читаются отдельными потоками: если читать их
  # последовательно, команда с большим выводом заблокируется на переполненном
  # буфере пайпа, а мы будем ждать её вечно.
  #
  # Команда запускается в собственной группе процессов (pgroup: true), и KILL
  # шлётся группе, а не одному bash. Иначе умирает только сам bash, а его дети
  # продолжают жить с унаследованным концом пайпа — тот остаётся открытым,
  # чтение stdout не завершается, и агент виснет ровно на время жизни команды
  # (измерено: `sleep 1` — секунда, `sleep 8` — восемь). Ловится и Ctrl+C,
  # и таймаут, и даже штатный выход: `sleep 300 & echo привет` завершает bash
  # успешно, а агент после этого не возвращается вовсе.
  class ProcessRunner
    # U+FFFD вместо негодного байта: он же стоит в выводе `less` и подобных,
    # и человек, увидев его в результате, понимает, что смотрит на двоичные
    # данные, а не на испорченный текст.
    REPLACEMENT = "�"

    # Сколько ждать дочитывания вывода после того, как команда завершена или
    # убита. Секунды хватает с запасом: пайп к этому моменту уже закрыт, и
    # ожидание нужно только на случай ускользнувшего потомка.
    DRAIN_TIMEOUT = 1

    # Размер порции при чтении вывода команды.
    READ_CHUNK = 4096

    Result = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true) do
      def success?
        exit_code.zero?
      end
    end

    def initialize(timeout: 120, poll_interval: 0.1, cwd: nil)
      @timeout = timeout
      @poll_interval = poll_interval
      @cwd = cwd
    end

    attr_reader :timeout, :cwd

    # Бросает MiniAgent::TimeoutError, если команда не уложилась в @timeout.
    #
    # Каталог задаётся через chdir: у самого процесса, а не Dir.chdir: тот
    # меняет каталог всего агента, а значит и то, куда пишет лог и где ищется
    # описание проекта. Побочный эффект на весь процесс ради одной команды —
    # обмен, которого здесь не нужно.
    def call(command)
      Open3.popen3("bash", "-c", command, **spawn_options) do |stdin, stdout_io, stderr_io, wait_thr|
        stdin.close
        out_reader = reader_for(stdout_io)
        err_reader = reader_for(stderr_io)

        wait_or_kill(wait_thr, out_reader, err_reader)
        # Команда завершилась, но оставленный ею фоновый процесс держит пайп:
        # без ограниченного ожидания чтение не вернулось бы вовсе.
        drain(out_reader, err_reader)

        Result.new(
          stdout: text(out_reader[:buffer]),
          stderr: text(err_reader[:buffer]),
          exit_code: exit_code_for(wait_thr.value)
        )
      end
    end

    private

    # pgroup: true — своя группа процессов на команду: только так KILL достаёт
    # всех потомков разом (см. комментарий к классу).
    def spawn_options
      options = { pgroup: true }
      options[:chdir] = @cwd if @cwd
      options
    end

    # Вывод команды — произвольные байты, а не обязательно текст. Ruby помечает
    # его UTF-8, не проверяя содержимого, и первый же `head -c 30 /bin/ls`
    # ронял агента насквозь: JSON::GeneratorError при сборке тела запроса,
    # сырой бэктрейс вместо ответа (проверено живьём). Чинить это в JSON поздно
    # — испорченная строка успевает разойтись по истории и логу, поэтому
    # заменяем негодные байты здесь, на самой границе с внешним миром.
    # Помечать байты UTF-8 приходится здесь явно: readpartial отдаёт их
    # в ASCII-8BIT, и без пометки русский вывод доехал бы до модели
    # нечитаемой последовательностью \xD0\xBF вместо букв.
    def text(value)
      string = value.to_s.dup.force_encoding(Encoding::UTF_8)
      return string if string.valid_encoding?

      string.scrub(REPLACEMENT)
    end

    def wait_or_kill(wait_thr, out_reader, err_reader)
      deadline = monotonic_now + @timeout

      until wait_thr.join(@poll_interval)
        next if monotonic_now < deadline

        kill(wait_thr.pid)
        # Дожидаемся читателей, иначе потоки останутся висеть на закрытых пайпах.
        drain(out_reader, err_reader)
        raise TimeoutError, format(Messages::EXECUTION_TIMEOUT, timeout: @timeout.round)
      end
    # Ctrl+C во время команды: процесс надо убить явно и здесь. Сигнал от
    # терминала уходит группе, но команда могла сменить группу сама
    # (`setsid`) или перехватить INT и продолжить работу — тогда без KILL
    # она пережила бы прерывание и осталась висеть в фоне. Ровно та же
    # причина, по которой здесь не используется Timeout.timeout.
    rescue Interrupt
      kill(wait_thr.pid)
      drain(out_reader, err_reader)
      raise
    end

    # Читатель копит прочитанное в буфер, а не возвращает его из потока:
    # поток можно снять, не потеряв то, что команда успела написать. Через
    # Thread#value это не выходит — у снятого потока значения уже нет.
    #
    # readpartial, а не read: тот ждёт либо полный буфер, либо EOF, а EOF не
    # придёт, пока оставленный командой фоновый процесс держит свой конец
    # пайпа. Вывод в этом случае теряется целиком — `sleep 300 & echo привет`
    # возвращал пустую строку вместо «привет».
    def reader_for(io)
      state = { buffer: +"" }
      state[:thread] = Thread.new do
        loop { state[:buffer] << io.readpartial(READ_CHUNK) }
      rescue IOError
        # EOFError (команда дописала) — тоже IOError, как и закрытый из другого
        # потока пайп: в обоих случаях читать больше нечего.
      end
      state
    end

    # Читатели после KILL должны завершиться сами — пайп закрылся вместе
    # с группой. Ожидание всё же ограничено: если какой-то потомок ускользнул
    # (сменил группу через setsid), лучше отдать неполный вывод, чем подвесить
    # агента насмерть. Потоки при этом снимаются, иначе они переживут команду.
    def drain(*readers)
      readers.each do |reader|
        thread = reader[:thread]
        thread.kill unless thread.join(DRAIN_TIMEOUT)
      end
    end

    # KILL уходит всей группе (отрицательный pid), а не одному bash: его дети
    # иначе остаются жить и держат пайп открытым.
    def kill(pid)
      Process.kill("KILL", -Process.getpgid(pid))
    rescue Errno::ESRCH, Errno::EPERM
      # Процесс уже завершился сам — убивать нечего.
      nil
    end

    # После KILL exitstatus равен nil, поэтому берём номер сигнала + 128,
    # как это делает shell.
    def exit_code_for(status)
      status.exitstatus || (status.termsig ? 128 + status.termsig : -1)
    end

    # Монотонные часы: невосприимчивы к переводу системного времени.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
