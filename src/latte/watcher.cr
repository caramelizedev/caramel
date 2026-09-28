require "c/fcntl"
require "c/sys/event"
require "c/sys/resource"

lib LibC
  O_EVTONLY    =     0x00008000
  EVFILT_VNODE =         -4_i16
  NOTE_DELETE  = 0x00000001_u32
  NOTE_WRITE   = 0x00000002_u32
  NOTE_EXTEND  = 0x00000004_u32
  NOTE_ATTRIB  = 0x00000008_u32
  NOTE_RENAME  = 0x00000020_u32
  NOTE_REVOKE  = 0x00000040_u32
  OPEN_MAX     =          10240

  fun setrlimit(Int, Rlimit*) : Int
end

module Caramel::Latte
  # Recursive macOS kqueue watcher (RFC-0004 §2.1). Each watched directory and
  # file is held open with O_EVTONLY. A directory event rescans that directory,
  # so new entries gain watches and vanished ones release theirs. Missing
  # watched paths are picked up through their parent directories ("anchors").
  #
  # Crystal 1.21's kqueue event loop registers EVFILT_READ and EVFILT_WRITE
  # for every descriptor it waits on, and a kqueue descriptor rejects
  # EVFILT_WRITE with EINVAL, so the event loop cannot wait on this kqueue.
  # `#changed?` therefore drains it with a zero timeout and sleeps between
  # checks; the calling fiber never blocks the scheduler.
  class Watcher
    NOTES    = LibC::NOTE_WRITE | LibC::NOTE_EXTEND | LibC::NOTE_ATTRIB | LibC::NOTE_DELETE | LibC::NOTE_RENAME | LibC::NOTE_REVOKE
    GONE     = LibC::NOTE_DELETE | LibC::NOTE_RENAME | LibC::NOTE_REVOKE
    INTERVAL = 25.milliseconds

    class Error < Exception
    end

    private enum Kind
      Anchor    # a directory above a watched path; its entries are not watched
      Directory # recursive
      File
    end

    private record Watch, id : UInt64, path : String, kind : Kind, fd : Int32, device : Int32, inode : UInt64

    @watches = {} of UInt64 => Watch
    @paths = {} of String => UInt64
    @next_id = 0_u64
    @events = Slice(LibC::Kevent).new(64) { LibC::Kevent.new }
    @anchors = [] of String
    @targets : Array(String)
    @kq : Int32

    # Watches each of *relative_paths* under *root*: directories recursively,
    # files directly. Paths may be missing; they are watched once created.
    def initialize(root : String, relative_paths : Array(String))
      @root = Path[root].expand.normalize.to_s
      @targets = relative_paths.map { |relative| Path[@root, relative].normalize.to_s }.uniq!
      @targets.each do |target|
        parent = File.dirname(target)
        while parent.starts_with?(@root) && !@targets.includes?(parent)
          @anchors << parent unless @anchors.includes?(parent)
          break if parent == @root
          parent = File.dirname(parent)
        end
      end
      # Outer anchors first: replacing one drops every watch beneath it.
      @anchors.sort_by!(&.size)
      raise_descriptor_limit
      @kq = LibC.kqueue
      raise Error.new("kqueue: #{Errno.value.message}") if @kq == -1
      LibC.fcntl(@kq, LibC::F_SETFD, LibC::FD_CLOEXEC)
      reconcile
    end

    # Returns true as soon as a watched path changes, or false once *timeout*
    # passes without a change.
    def changed?(timeout : Time::Span) : Bool
      raise Error.new("Watcher is closed") if closed?
      deadline = Time.instant + timeout
      loop do
        return true if drain
        remaining = deadline - Time.instant
        return false unless remaining.positive?
        sleep(remaining < INTERVAL ? remaining : INTERVAL)
      end
    end

    def close : Nil
      return if closed?
      @watches.each_value { |watch| LibC.close(watch.fd) }
      @watches.clear
      @paths.clear
      LibC.close(@kq)
      @kq = -1
    end

    def closed? : Bool
      @kq == -1
    end

    def finalize
      close
    end

    private def drain : Bool
      changed = false
      timeout = LibC::Timespec.new(tv_sec: 0, tv_nsec: 0)
      loop do
        count = LibC.kevent(@kq, nil, 0, @events.to_unsafe, @events.size, pointerof(timeout))
        if count == -1
          next if Errno.value == Errno::EINTR
          raise Error.new("kevent: #{Errno.value.message}")
        end
        @events[0, count].each do |event|
          # A watch removed earlier in this batch may have had its descriptor reused.
          next unless watch = @watches[event.udata.address]?
          changed = true
          if event.fflags & GONE != 0
            remove(watch)
          elsif watch.kind.anchor?
            reconcile
          elsif watch.kind.directory?
            rescan(watch.path)
          end
        end
        return changed if count < @events.size
      end
    end

    private def reconcile : Nil
      @anchors.each { |path| watch(path, anchor: true) }
      @targets.each { |path| watch(path, anchor: false) }
    end

    private def rescan(directory : String) : Nil
      names = begin
        Dir.children(directory).reject(&.starts_with?('.'))
      rescue File::Error
        [] of String
      end
      prefix = directory + "/"
      stale = @paths.keys.select { |path| path.starts_with?(prefix) && !path.index('/', prefix.size) && !names.includes?(path[prefix.size..]) }
      stale.each { |path| @paths[path]?.try { |id| remove(@watches[id]) } }
      names.each { |name| watch(prefix + name, anchor: false) }
    end

    # Opens *path* before listing a directory's entries, so an entry created
    # meanwhile is either listed or reported by the new watch.
    # ameba:disable Metrics/CyclomaticComplexity -- one branch per kqueue registration outcome
    private def watch(path : String, anchor : Bool) : Nil
      existing = @paths[path]?.try { |id| @watches[id] }
      status = uninitialized LibC::Stat
      unless LibC.lstat(path, pointerof(status)) == 0 && watchable?(status, anchor)
        remove(existing) if existing
        return
      end
      return if existing && existing.device == status.st_dev && existing.inode == status.st_ino
      remove(existing) if existing
      fd = LibC.open(path, LibC::O_EVTONLY | LibC::O_CLOEXEC | LibC::O_NOFOLLOW)
      if fd == -1
        raise Error.new("Too many files to watch under #{@root}: #{Errno.value.message}") if Errno.value.in?(Errno::EMFILE, Errno::ENFILE)
        return # vanished or replaced by a symlink; the parent reports it
      end
      unless LibC.fstat(fd, pointerof(status)) == 0 && watchable?(status, anchor)
        LibC.close(fd)
        return
      end
      kind = directory?(status) ? (anchor ? Kind::Anchor : Kind::Directory) : Kind::File
      id = @next_id += 1
      event = LibC::Kevent.new(ident: fd.to_u64, filter: LibC::EVFILT_VNODE, flags: LibC::EV_ADD | LibC::EV_CLEAR, fflags: NOTES, data: 0, udata: Pointer(Void).new(id))
      if LibC.kevent(@kq, pointerof(event), 1, nil, 0, nil) == -1
        message = Errno.value.message
        LibC.close(fd)
        raise Error.new("kevent: #{message}")
      end
      @watches[id] = Watch.new(id, path, kind, fd, status.st_dev, status.st_ino)
      @paths[path] = id
      rescan(path) if kind.directory?
    end

    private def directory?(status : LibC::Stat) : Bool
      status.st_mode.to_i32 & LibC::S_IFMT == LibC::S_IFDIR
    end

    # Anchors are directories; symlinks and special files are never followed.
    private def watchable?(status : LibC::Stat, anchor : Bool) : Bool
      directory?(status) || (!anchor && status.st_mode.to_i32 & LibC::S_IFMT == LibC::S_IFREG)
    end

    private def remove(watch : Watch) : Nil
      prefix = watch.path + "/"
      [watch.path].concat(@paths.keys.select(&.starts_with?(prefix))).each do |path|
        next unless id = @paths.delete(path)
        if removed = @watches.delete(id)
          LibC.close(removed.fd)
        end
      end
    end

    # One descriptor per watched entry; macOS shells start at a 256 soft limit.
    private def raise_descriptor_limit : Nil
      limit = LibC::Rlimit.new
      return unless LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(limit)) == 0
      wanted = Math.min(limit.rlim_max, LibC::OPEN_MAX.to_u64)
      return if limit.rlim_cur >= wanted
      limit.rlim_cur = wanted
      LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(limit))
    end
  end
end
