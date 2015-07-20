require 'json'
require 'abstractive/actor'
require 'abstractive/timespans'

class Abstractive::Proceso < Abstractive::Actor

  include Abstractive::TimeSpans

  class << self
    def start!(options={})
      name = options.delete(:name) || :cellumon
      unless options.fetch(:monitors, nil).is_a? Array
        puts "Cellumon > No monitors specified"
        return
      end
      Cellumon.supervise(as: name, args: [options])
      Celluloid[name]
    end
  end

  MONITORS = {
    uptime: 90,
    thread_survey: 30,
    thread_report: 15,
    thread_summary: 3,
    memory_count: 13,
    threads_and_memory: 45
  }

  def initialize(options={})
    @semaphor = {}
    @status = {}
    @timers = {}
    @debug = options.fetch(:debug, false)
    @logger = options.fetch(:logger, nil)
    @mark = options.fetch(:mark, false)
    @intervals = MONITORS.dup
    @options = options
    @start = Time.now
    async.start
  end

  def start
    if @options[:monitors].is_a?(Array)
      debug("Monitors:") if @debug
      @options[:monitors].each { |monitor|
        debug("* #{monitor} every #{readable_duration(MONITORS[monitor])}.") if @debug
        send("start_#{monitor}!")
      }
    else
      debug("No preconfigured monitors.") if @debug
    end
  end

  MONITORS.each { |m,i|
    define_method(:"start_#{m}!") { |interval=nil|
      async.send(:"starting_#{m}")
    }
    define_method(:"starting_#{m}") { |interval=nil|
      @intervals[m] = interval || MONITORS[m]
      @timers[m] = nil
      @semaphor[m] = Mutex.new
      @status[m] = :initializing
      async.send :"#{m}!"
      ready! m
    }
    define_method(:"stop_#{m}!") {
      stopped! m
      @timers[m].cancel if @timers[m]
    }
  }
    
  def uptime!
    trigger!(:uptime) { console "Uptime: #{readable_duration(duration(Time.now, @start)}" }
  end
    
  def memory_count!
    trigger!(:memory_count) { console memory }
  end

  def thread_survey!
    trigger!(:thread_survey) { Celluloid.stack_summary }
  end

  def thread_summary!
    trigger!(:thread_summary) { print " #{Thread.list.count} " }
  end

  def thread_report!
    trigger!(:thread_report) { console threads }
  end

  def threads_and_memory!
    trigger!(:threads_and_memory) { console "#{threads}; #{memory}" }
  end

  private

  def threads
    threads = Thread.list.inject({}) { |l,t| l[t.object_id] = t.status; l }
    r = threads.select { |id,status| status == 'run' }.count
    s = threads.select { |id,status| status == 'sleep' }.count
    a = threads.select { |id,status| status == 'aborting' }.count
    nt = threads.select { |id,status| status === false }.count
    te = threads.select { |id,status| status.nil? }.count
    "Threads #{threads.count}: #{r}r #{s}s #{a}a #{nt}nt #{te}te"
  end

  def memory
    total = `pmap #{Process.pid} | tail -1`[10,40].strip[0..-1].to_i
    gb = (total / (1024 * 1024)).to_i
    mb = total % gb
    "Memory: #{'%0.2f' % "#{gb}.#{mb}"}gb" #de Very fuzzy math but fine for now.
  end

  def trigger!(monitor)
    puts "trigger: #{monitor}" if @debug
    if ready?(monitor)
      result = yield
      ready! monitor
    end
    @timers[monitor].cancel rescue nil
    @timers[monitor] = after(@intervals[monitor]) { send("#{monitor}!") }
    result
  rescue => ex
    exception(ex, "Cellumon > Failure to trigger: #{monitor}")
  end

  def mark
    @mark ? "Cellumon > " : ""
  end

  [:ready, :running, :stopped].each { |state|
    define_method("#{state}!") { |monitor|
      @semaphor[monitor].synchronize { @status[monitor] = state }
    }
    define_method("#{state}?") { |monitor|
      @semaphor[monitor].synchronize { @status[monitor] == state }
    }
  }

end